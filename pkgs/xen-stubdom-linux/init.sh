#!/bin/sh
# init of the Linux device-model stubdomain (protocol: xen
# docs/misc/stubdom.txt, "Toolstack to Linux ioemu stubdomain protocol").
# Follows the init of Qubes OS (QubesOS/qubes-vmm-xen-stubdom-linux,
# rootfs/init) without audio, qrexec/USB and save/restore.

set -e
/bin/busybox --install -s /bin
export PATH=/bin

# make-initrd-ng only creates the directories of the files it installs
mkdir -p /dev /sys /proc /tmp
mount -t devtmpfs none /dev
mount -t sysfs sysfs /sys
mount -t proc proc /proc
mount -t xenfs xenfs /proc/xen
mount -t tmpfs -o size=1m,nodev,noexec tmpfs /tmp
mkdir -p /dev/shm
mount -t tmpfs -o size=1m,nodev,noexec tmpfs /dev/shm
mount -o remount,ro /

# Not on the console: nothing in dom0 drains it (see kernel.config), a full
# ring blocks every writer. The log is bounded by the size of /tmp
exec >/tmp/init.log 2>&1

echo 1 > /proc/sys/vm/overcommit_memory
if [ -w /sys/module/xen_gntalloc/parameters/limit ]; then
  printf '%d\n' "$((1 << 30))" > /sys/module/xen_gntalloc/parameters/limit
fi

target=$(xenstore-read target)
vm_path=$(xenstore-read "/local/domain/$target/vm")
device_model="device-model/$target"

# qemu arguments, one per line (the toolstack writes one key per argument)
dm_args=$(
  for key in $(xenstore-list "$vm_path/image/dm-argv" | sort); do
    xenstore-read "$vm_path/image/dm-argv/$key"
  done
)
# no save/restore support: drop a restore request
# shellcheck disable=SC2016
dm_args=$(printf '%s\n' "$dm_args" | sed '/\$STUBDOM_RESTORE_INCOMING_ARG/d; /^-incoming$/d')

# The guest's NIC: qemu's tap device and the stubdomain's PV vif (eth0)
# share a bridge, so the guest is on the network the vif's backend serves
if [ -e /sys/class/net/eth0 ]; then
  ip link set eth0 address fe:ff:ff:ff:ff:fe
  ip addr flush dev eth0
  ip link set eth0 up
  brctl addbr br0
  brctl addif br0 eth0
  ip link set br0 up
fi

# Optional VNC display (device_model_args = [ "-vnc", "unix:/tmp/vnc.sock" ]),
# exported to dom0 over vchan like QMP
vnc=
if printf '%s\n' "$dm_args" | grep -qx 'unix:/tmp/vnc.sock'; then
  vnc=1
fi

# Arguments are separated by newlines, so they may contain spaces
IFS='
'
set -f
# shellcheck disable=SC2086
qemu -L /share/qemu \
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
  -chardev socket,server=on,wait=off,path=/tmp/qemu.qmp,id=m \
  -mon chardev=m,mode=control \
  $dm_args &
qemu_pid=$!
set +f
unset IFS

# libxl passes script=no: join qemu's tap device (ifname=…) to the bridge
# once qemu has created it
ifname=$(printf '%s\n' "$dm_args" | sed -n 's/^type=tap,.*ifname=\([^,]*\).*$/\1/p' | head -n 1)
if [ -n "$ifname" ] && [ -e /sys/class/net/br0 ]; then
  (
    while [ ! -e "/sys/class/net/$ifname" ]; do sleep 0.1; done
    ip link set "$ifname" down
    ip link set "$ifname" address fe:ff:ff:ff:ff:fd
    ip addr flush dev "$ifname"
    brctl addif br0 "$ifname"
    ip link set "$ifname" up
  ) &
fi

# If qemu fails, end the stubdomain: libxl then reports the failure at once
# instead of waiting for its startup timeout
while [ ! -S /tmp/qemu.qmp ]; do
  kill -0 "$qemu_pid" 2>/dev/null || poweroff -f
  sleep 0.1
done
# QMP for the toolstack (dom0 runs the client side of vchan-socket-proxy)
vchan-socket-proxy --mode=server 0 "$device_model/qmp-vchan" /tmp/qemu.qmp &

if [ -n "$vnc" ]; then
  while [ ! -S /tmp/vnc.sock ]; do sleep 0.1; done
  vchan-socket-proxy --mode=server 0 "$device_model/vnc-vchan" /tmp/vnc.sock &
fi

# The stubdomain lives as long as qemu
wait "$qemu_pid" || true
poweroff -f
