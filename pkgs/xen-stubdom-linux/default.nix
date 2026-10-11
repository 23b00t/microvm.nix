# Linux-based device-model stubdomain for Xen HVM guests: a small PV kernel
# and an initramfs that runs qemu for the guest, so the device model does not
# run in dom0. Used via `microvm.xen.stubdomain` (xl `stubdomain_kernel`,
# `stubdomain_ramdisk`). Modeled after Qubes OS' qubes-vmm-xen-stubdom-linux.
#
# Not supported (yet): PCI passthrough (needs the Qubes qemu patches),
# save/restore, audio, USB.
{
  lib,
  stdenv,
  runCommand,
  linux_6_6,
  qemu,
  pixman,
  xen,
  pkgsStatic,
  makeInitrdNG,
  bc,
  bison,
  flex,
  perl,
  elfutils,
}:

let
  kernel = stdenv.mkDerivation {
    pname = "xen-stubdom-linux-kernel";
    inherit (linux_6_6) version src;

    patches = [ ./hvc-raw-mode.patch ];

    nativeBuildInputs = [
      bc
      bison
      flex
      perl
      elfutils
    ];

    # allnoconfig plus the fragment; then check that the symbols the
    # stubdomain cannot work without survived the dependency resolution
    configurePhase = ''
      runHook preConfigure
      make allnoconfig KCONFIG_ALLCONFIG=${./kernel.config}
      for sym in XEN_PV XENFS XEN_PRIVCMD XEN_DEV_EVTCHN XEN_GNTDEV \
                 XEN_GRANT_DEV_ALLOC HVC_XEN XEN_NETDEV_FRONTEND \
                 XEN_BLKDEV_FRONTEND BLK_DEV_INITRD RD_GZIP DEVTMPFS TUN \
                 BRIDGE UNIX SECCOMP_FILTER EVENTFD; do
        grep -qx "CONFIG_$sym=y" .config || {
          echo "missing CONFIG_$sym in the stubdomain kernel config" >&2
          exit 1
        }
      done
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      make -j$NIX_BUILD_CORES bzImage
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 arch/x86/boot/bzImage $out/bzImage
      install -Dm644 .config $out/config
      runHook postInstall
    '';
  };

  # Only the system emulator for Xen HVM: no GUI, audio or USB redirection;
  # VNC stays for an optional display exported over vchan
  qemuStubdom =
    (qemu.override {
      xenSupport = true;
      minimal = true;
      seccompSupport = true;
      vncSupport = true;
      enableBlobs = true;
      hostCpuTargets = [ "i386-softmmu" ];
    }).overrideAttrs
      (old: {
        # VNC needs pixman, which `minimal` leaves out (VNC would silently be off)
        buildInputs = old.buildInputs ++ [ pixman ];
        configureFlags = old.configureFlags ++ [
          "--enable-pixman"
          "--enable-vnc"
        ];
      });

  # The firmware qemu loads itself (hvmloader brings SeaBIOS); `-L
  # /share/qemu` in the init points qemu here
  qemuData = runCommand "xen-stubdom-qemu-data" { } ''
    mkdir -p $out
    for f in vgabios-stdvga.bin vgabios-cirrus.bin linuxboot_dma.bin \
             kvmvapic.bin efi-e1000.rom efi-rtl8139.rom efi-virtio.rom; do
      cp ${qemuStubdom}/share/qemu/$f $out/
    done
    # VNC loads the keyboard layout (default en-us) at startup
    cp -r ${qemuStubdom}/share/qemu/keymaps $out/
  '';

  busybox = pkgsStatic.busybox;

  rootfs = makeInitrdNG {
    name = "xen-stubdom-linux-rootfs";
    compressor = "gzip";
    contents = [
      {
        source = ./init.sh;
        target = "/init";
      }
      {
        source = "${busybox}/bin/busybox";
        target = "/bin/busybox";
      }
      {
        source = "${busybox}/bin/busybox";
        target = "/bin/sh";
      }
      {
        source = "${qemuStubdom}/bin/qemu-system-i386";
        target = "/bin/qemu";
      }
      {
        source = qemuData;
        target = "/share/qemu";
      }
      {
        source = "${xen}/bin/vchan-socket-proxy";
        target = "/bin/vchan-socket-proxy";
      }
    ]
    # The Xen libraries still link the glibc compat stubs, which make-initrd-ng
    # does not find on their RUNPATH
    ++
      map
        (name: {
          source = "${stdenv.cc.libc}/lib/${name}";
          target = "/lib/${name}";
        })
        [
          "libdl.so.2"
          "libpthread.so.0"
        ]
    ++
      map
        (tool: {
          source = "${xen}/bin/${tool}";
          target = "/bin/${tool}";
        })
        [
          "xenstore-read"
          "xenstore-write"
          "xenstore-list"
          "xenstore-rm"
        ];
  };
in
runCommand "xen-stubdom-linux-${kernel.version}"
  {
    passthru = {
      inherit kernel rootfs;
      qemu = qemuStubdom;
    };
    meta.platforms = [ "x86_64-linux" ];
  }
  ''
    mkdir -p $out
    ln -s ${kernel}/bzImage $out/qemu-stubdom-linux-kernel
    ln -s ${rootfs}/initrd $out/qemu-stubdom-linux-rootfs
  ''
