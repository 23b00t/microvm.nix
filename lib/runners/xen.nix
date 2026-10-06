{ pkgs
, microvmConfig
, withDriveLetters
, ...
}:

let
  inherit (pkgs) lib;

  inherit (microvmConfig)
    hostName preStart user
    vcpu mem balloon initialBalloonMem hotplugMem hotpluggedMem
    interfaces devices vsock graphics forwardPorts credentialFiles
    kernel initrdPath storeDisk storeOnDisk;

  inherit (import ../. { inherit lib; }) firstDiskIndex;

  xenPackage = microvmConfig.xen.package;
  inherit (microvmConfig.xen) type;
  isHvm = type == "hvm";
  xl = "${xenPackage}/bin/xl";
  scriptDir = "${xenPackage}/etc/xen/scripts";

  # Hotplug script for `type = "tap"` interfaces: Xen creates a vif in dom0
  # named after the interface id instead of a tap device. Like the tap
  # interfaces of the other hypervisors, it is only brought up; attaching it
  # to a bridge is left to the host network configuration.
  # The Xen helper scripts locate each other via `dirname "$0"`, so the
  # script must live in a directory next to them.
  vifScript = microvmConfig.vmHostPackages.runCommand "microvm-xen-scripts" { } ''
    mkdir $out
    ln -s ${scriptDir}/* $out/
    cp ${vifScriptText} $out/microvm-xen-vif
  '' + "/microvm-xen-vif";

  vifScriptText = microvmConfig.vmHostPackages.writeShellScript "microvm-xen-vif" ''
    dir=$(${lib.getExe' microvmConfig.vmHostPackages.coreutils "dirname"} "$0")
    . "$dir/vif-common.sh"

    case "$command" in
      add|online)
        setup_bridge_port "$dev"
        do_or_die ${lib.getExe' microvmConfig.vmHostPackages.iproute2 "ip"} link set dev "$dev" up
        ;;
      remove|offline)
        do_without_error ${lib.getExe' microvmConfig.vmHostPackages.iproute2 "ip"} link set dev "$dev" down
        ;;
    esac

    log debug "Successful microvm-xen-vif $command for $dev."
    if [ "$type_if" = vif ] && [ "$command" = online ]; then
      success
    fi
  '';

  # xl.cfg strings are C-like double-quoted strings
  quote = builtins.toJSON;

  # Relative volume images are created in the working directory (the
  # MicroVM's state directory), but xl needs absolute paths. The
  # placeholder is substituted when writing xl.cfg.
  absolutePath = path:
    if lib.hasPrefix "/" path
    then path
    else "@STATE_DIR@/${path}";

  storeDiskLetter = builtins.elemAt lib.strings.lowerChars (firstDiskIndex microvmConfig);

  disks =
    lib.optional storeOnDisk
      "format=raw, vdev=xvd${storeDiskLetter}, access=ro, target=${storeDisk}"
    ++
    map ({ image, letter, readOnly, serial, direct, ... }:
      lib.warnIf (serial != null) "Volume serial is not supported for xen" (
        lib.warnIf direct "Volume direct I/O is not supported for xen"
          "format=raw, vdev=xvd${letter}, access=${if readOnly then "ro" else "rw"}, target=${absolutePath image}"
      )
    ) (withDriveLetters microvmConfig);

  # HVM: only the PV nic, no emulated one next to it
  vifType = lib.optionalString isHvm "type=vif, ";

  inherit (microvmConfig.xen) interfaceBackends driverDomain;

  # Interfaces served by a driver domain: the hotplug script runs there, so
  # only bridges (living in the driver domain) are possible, no dom0 tap script.
  backendOf = id: interfaceBackends.${id} or null;

  vifs = map ({ type, id, mac, bridge, ... }:
    if backendOf id != null
    then
      if type != "bridge" || bridge == null
      then throw "xen: interface ${id} with a backend domain must be of type bridge with a bridge in that domain"
      # No vifname: the upstream hotplug scripts derive the frontend domid from
      # the default name vif<domid>.<devid> (set_mtu) and fail on a renamed vif
      else "${vifType}mac=${mac}, bridge=${bridge}, backend=${backendOf id}"
    else if type == "tap"
    then "${vifType}mac=${mac}, vifname=${id}, script=${vifScript}"
    else if type == "bridge"
    then
      if bridge == null
      then throw "xen: interface ${id} of type bridge needs a bridge"
      else "${vifType}mac=${mac}, vifname=${id}, bridge=${bridge}"
    else throw "interface type ${type} is not supported by xen"
  ) interfaces;

  xlList = items:
    "[ ${lib.concatMapStringsSep ", " quote items} ]";

  # Xen balloons between `memory` (boot) and `maxmem` (ceiling); growing and
  # shrinking at runtime is done with `xl mem-set` from dom0.
  # Same meaning as for the other hypervisors: with `balloon`, `mem` is the
  # ceiling and `initialBalloonMem` is taken away at boot; with
  # `hotplugMem`, the ceiling is `mem + hotplugMem` and the VM boots with
  # `mem + hotpluggedMem`.
  maxMem =
    if hotplugMem != 0
    then mem + hotplugMem
    else mem;
  bootMem =
    if hotplugMem != 0
    then mem + hotpluggedMem
    else mem - initialBalloonMem;

  # PVH/PV load the ELF vmlinux; for HVM, qemu boots a bzImage via SeaBIOS
  kernelImage =
    if isHvm
    then "${kernel}/bzImage"
    else "${kernel.dev}/vmlinux";

  # Headless HVM with the qemu device model running in dom0
  hvmConfig = lib.optionalString isHvm ''
    device_model_version = "qemu-xen"
    device_model_override = ${quote "${microvmConfig.xen.qemuPackage}/bin/qemu-system-i386"}
    vga = "none"
    vnc = 0
    sdl = 0
  '';

  pciDevices = builtins.filter ({ bus, ... }: bus == "pci") devices;
  usbDevices = builtins.filter ({ bus, ... }: bus == "usb") devices;

  # Devices are made assignable (pciback) by the host's pci-setup script
  pciConfig = lib.optionalString (pciDevices != [ ]) ''
    pci = ${xlList (map ({ path, ... }: path) pciDevices)}
  '';

  inherit (microvmConfig.xen) maxvcpus cpus pool weight cap onCrash;

  # CPU placement and scheduling, only set when configured
  cpuConfig = lib.concatStrings (
    lib.optional (maxvcpus != null) "maxvcpus = ${toString maxvcpus}\n"
    ++ lib.optional (cpus != null) "cpus = ${quote cpus}\n"
    ++ lib.optional (pool != null) "pool = ${quote pool}\n"
    ++ lib.optional (weight != null) "cpu_weight = ${toString weight}\n"
    ++ lib.optional (cap != null) "cap = ${toString cap}\n"
  );

  xlConfig = ''
    name = ${quote hostName}
    type = ${quote type}
    kernel = ${quote kernelImage}
    ramdisk = ${quote initrdPath}
    cmdline = ${quote "console=hvc0 panic=-1 ${toString microvmConfig.kernelParams}"}
    memory = ${toString bootMem}
    maxmem = ${toString maxMem}
    vcpus = ${toString vcpu}
    ${cpuConfig}
    on_poweroff = "destroy"
    on_reboot = "destroy"
    on_crash = ${quote onCrash}
    disk = ${xlList disks}
    vif = ${xlList vifs}
    ${hvmConfig}
    ${pciConfig}
    ${lib.optionalString driverDomain "driver_domain = 1"}
    ${microvmConfig.xen.extraConfig}
  '';

  # Destroy a leftover domain of the same name, e.g. after the xl process
  # was killed without shutting the guest down.
  destroyStale = ''
    if ${xl} domid ${lib.escapeShellArg hostName} >/dev/null 2>&1; then
      echo "Destroying leftover Xen domain ${hostName}" >&2
      ${xl} destroy ${lib.escapeShellArg hostName}
    fi
  '';

in
if !pkgs.stdenv.hostPlatform.isx86_64
then throw "xen is only supported on x86_64-linux"
else if user != null
then throw "xen does not support changing the user; the MicroVM service runs as root"
else if !storeOnDisk
then throw "xen requires microvm.storeOnDisk (there are no virtiofs/9p shares)"
else if balloon && hotplugMem != 0
then throw "xen: use either microvm.balloon or microvm.hotplugMem, not both"
else if !balloon && initialBalloonMem != 0
then throw "xen: microvm.initialBalloonMem needs microvm.balloon"
else if initialBalloonMem >= mem
then throw "xen: microvm.initialBalloonMem must be smaller than microvm.mem"
else if hotpluggedMem > hotplugMem
then throw "xen: microvm.hotpluggedMem must not exceed microvm.hotplugMem"
else if builtins.any (id: !builtins.elem id (map ({ id, ... }: id) interfaces)) (builtins.attrNames interfaceBackends)
then throw "xen: microvm.xen.interfaceBackends names an interface id that does not exist"
else if usbDevices != [ ]
then throw "xen: USB passthrough is not supported; pass the USB controller (bus = \"pci\") to a driver domain instead"
else if pciDevices != [ ] && !isHvm
then throw "xen: PCI passthrough needs microvm.xen.type = \"hvm\" (PVH dom0 only passes PCI devices to HVM guests)"
else if pciDevices != [ ] && bootMem != maxMem
then throw "xen: PCI passthrough needs the full memory at boot (no populate-on-demand); don't set initialBalloonMem or hotpluggedMem below hotplugMem"
else if maxvcpus != null && maxvcpus < vcpu
then throw "xen: microvm.xen.maxvcpus must not be smaller than microvm.vcpu"
else if vsock.cid != null
then throw "xen does not support vsock"
else if graphics.enable
then throw "xen does not support graphics"
else if forwardPorts != [ ]
then throw "xen does not support forwardPorts (no user networking)"
else if credentialFiles != { }
then throw "xen does not support credentialFiles"
else {
  preStart = ''
    ${preStart}
    ${destroyStale}
    ${lib.getExe' microvmConfig.vmHostPackages.gnused "sed"} "s|@STATE_DIR@|$PWD|g" \
      ${microvmConfig.vmHostPackages.writeText "xl.cfg" xlConfig} > xl.cfg
  '';

  command = "${xl} create -F xl.cfg";

  canShutdown = true;

  # `microvm-balloon <size-mb>`: the balloon takes SIZE away from the ceiling.
  # Timeout because xl blocks while another xl call holds the domain lock.
  setBalloonScript =
    if balloon || hotplugMem != 0
    then ''
      ${lib.getExe' microvmConfig.vmHostPackages.coreutils "timeout"} 30 \
        ${xl} mem-set ${lib.escapeShellArg hostName} "$(( ${toString maxMem} - SIZE ))m"
    ''
    else null;

  # Clean shutdown, with a hard destroy if the guest does not react.
  # `xl shutdown -w` returns once the guest is down, but the `xl create -F`
  # process only cleans up the domain afterwards. Wait for that before
  # systemd kills the service, so no shut-down domain is left behind.
  shutdownCommand = ''
    if ${xl} domid ${lib.escapeShellArg hostName} >/dev/null 2>&1; then
      ${lib.getExe' microvmConfig.vmHostPackages.coreutils "timeout"} 60 \
        ${xl} shutdown -w ${lib.escapeShellArg hostName} ||
        ${xl} destroy ${lib.escapeShellArg hostName}
      for _ in {1..20}; do
        ${xl} domid ${lib.escapeShellArg hostName} >/dev/null 2>&1 || break
        ${lib.getExe' microvmConfig.vmHostPackages.coreutils "sleep"} 0.5
      done
    fi
  '';
}
