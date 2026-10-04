# Guest support for running as a Xen PVH domU (`microvm.hypervisor = "xen"`)
{ config, lib, ... }:

let
  cfg = config.microvm;
in
lib.mkIf (cfg.guest.enable && cfg.hypervisor == "xen") {
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
