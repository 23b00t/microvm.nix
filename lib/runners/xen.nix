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

  xenPackage = microvmConfig.xen.package;
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

  disks =
    lib.optional storeOnDisk
      "format=raw, vdev=xvda, access=ro, target=${storeDisk}"
    ++
    map ({ image, letter, readOnly, serial, direct, ... }:
      lib.warnIf (serial != null) "Volume serial is not supported for xen" (
        lib.warnIf direct "Volume direct I/O is not supported for xen"
          "format=raw, vdev=xvd${letter}, access=${if readOnly then "ro" else "rw"}, target=${absolutePath image}"
      )
    ) (withDriveLetters microvmConfig);

  vifs = map ({ type, id, mac, bridge, ... }:
    if type == "tap"
    then "mac=${mac}, vifname=${id}, script=${vifScript}"
    else if type == "bridge"
    then
      if bridge == null
      then throw "xen: interface ${id} of type bridge needs a bridge"
      else "mac=${mac}, vifname=${id}, bridge=${bridge}"
    else throw "interface type ${type} is not supported by xen"
  ) interfaces;

  xlList = items:
    "[ ${lib.concatMapStringsSep ", " quote items} ]";

  xlConfig = ''
    name = ${quote hostName}
    type = "pvh"
    kernel = ${quote "${kernel.dev}/vmlinux"}
    ramdisk = ${quote initrdPath}
    cmdline = ${quote "console=hvc0 panic=-1 ${toString microvmConfig.kernelParams}"}
    memory = ${toString mem}
    vcpus = ${toString vcpu}
    on_poweroff = "destroy"
    on_reboot = "destroy"
    on_crash = "destroy"
    disk = ${xlList disks}
    vif = ${xlList vifs}
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
else if balloon || initialBalloonMem != 0 || hotplugMem != 0 || hotpluggedMem != 0
then throw "xen does not support ballooning or memory hotplug yet"
else if devices != [ ]
then throw "xen does not support PCI/USB passthrough yet"
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

  # Clean shutdown, with a hard destroy if the guest does not react
  shutdownCommand = ''
    if ${xl} domid ${lib.escapeShellArg hostName} >/dev/null 2>&1; then
      ${lib.getExe' microvmConfig.vmHostPackages.coreutils "timeout"} 60 \
        ${xl} shutdown -w ${lib.escapeShellArg hostName} ||
        ${xl} destroy ${lib.escapeShellArg hostName}
    fi
  '';
}
