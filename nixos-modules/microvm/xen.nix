# Guest support for running as a Xen domU (`microvm.hypervisor = "xen"`)
{ config, lib, ... }:

let
  cfg = config.microvm;
in
lib.mkIf (cfg.guest.enable && cfg.hypervisor == "xen") (lib.mkMerge [
  {
    # Xen PV frontends for the storeDisk, volumes and network
    boot.initrd.kernelModules = [
      "xen_blkfront"
      "xen_netfront"
    ];

    # There is no virtiofs/9p transport on Xen yet
    warnings = map ({ tag, source, mountPoint, ... }:
      if source == "/nix/store"
      then "MicroVM ${config.networking.hostName}: share \"${tag}\" (/nix/store) is replaced by the storeDisk on xen"
      else "MicroVM ${config.networking.hostName}: share \"${tag}\" (${source} -> ${mountPoint}) is not supported on xen and is dropped"
    ) cfg.shares;
  }

  # Driver domain: serves backends (e.g. vifs) for other domains. `xl devd`
  # watches xenstore and runs the hotplug scripts here, like dom0 does.
  (lib.mkIf cfg.xen.driverDomain {
    boot.kernelModules = [
      "xen-netback"
      "xen-evtchn"
      "xen-gntdev"
      "xen-gntalloc"
      "xen-privcmd"
      "bridge"
    ];

    systemd.mounts = [{
      description = "Mount /proc/xen files";
      what = "xenfs";
      where = "/proc/xen";
      type = "xenfs";
      unitConfig.ConditionPathExists = [ "/proc/xen" "!/proc/xen/capabilities" ];
    }];

    # libxl runs the default hotplug scripts (vif-bridge, …) from here
    environment.etc."xen/scripts".source = "${cfg.xen.package}/etc/xen/scripts";

    systemd.services.xendriverdomain = {
      description = "Xen driver domain device daemon";
      requires = [ "proc-xen.mount" ];
      after = [ "proc-xen.mount" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "forking";
        ExecStart = "${cfg.xen.package}/bin/xl devd";
        # xl devd logs to /var/log/xen/xldevd.log
        LogsDirectory = "xen";
      };
    };
  })
])
