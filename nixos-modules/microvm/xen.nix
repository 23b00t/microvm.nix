# Guest support for running as a Xen domU (`microvm.hypervisor = "xen"`)
{ config, lib, ... }:

lib.mkIf (config.microvm.guest.enable && config.microvm.hypervisor == "xen") {
  # Xen PV frontends for the storeDisk, volumes and network
  boot.initrd.kernelModules = [
    "xen_blkfront"
    "xen_netfront"
  ];
}
