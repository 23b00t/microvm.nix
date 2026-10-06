{ config, lib, pkgs, ... }:

let
  self-lib = import ../../lib {
    inherit lib;
  };

  regInfo = pkgs.closureInfo {
    rootPaths = [ config.system.build.toplevel ];
  };

in
{
  options.microvm.storeDisk = with lib; mkOption {
    type = types.path;
    description = ''
      The read-only /nix/store image the guest boots from.

      Generated from `microvm.storeDiskContents` by default. Set it to an
      image built with `microvm.lib.buildStoreDisk` from the contents of
      several guests to share one image between them.
    '';
  };

  options.microvm.storeDiskContents = with lib; mkOption {
    type = with types; listOf package;
    description = ''
      Store paths whose closure goes into `microvm.storeDisk`.
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf (config.microvm.guest.enable && config.microvm.storeOnDisk) {
      # nixos/modules/profiles/hardened.nix forbids erofs.
      # HACK: Other NixOS modules populate
      # config.boot.blacklistedKernelModules depending on the boot
      # filesystems, so checking on that directly would result in an
      # infinite recursion.
      microvm.storeDiskType = lib.mkDefault (
        if config.security.virtualisation.flushL1DataCache == "always"
        then "squashfs"
        else "erofs"
      );
      boot.initrd.availableKernelModules = [
        config.microvm.storeDiskType
      ];

      microvm.storeDiskContents =
        [ config.system.build.toplevel ]
        ++
        lib.optional config.nix.enable regInfo;

      microvm.storeDisk = lib.mkDefault (self-lib.buildStoreDisk {
        inherit pkgs;
        type = config.microvm.storeDiskType;
        erofsFlags = config.microvm.storeDiskErofsFlags;
        squashfsFlags = config.microvm.storeDiskSquashfsFlags;
        contents = config.microvm.storeDiskContents;
      });
    })

    (lib.mkIf (config.microvm.registerClosure && config.nix.enable) {
      microvm.kernelParams = [
        "regInfo=${regInfo}/registration"
      ];
      boot.postBootCommands = ''
        if [[ "$(cat /proc/cmdline)" =~ regInfo=([^ ]*) ]]; then
          ${config.nix.package.out}/bin/nix-store --load-db < ''${BASH_REMATCH[1]}
        fi
      '';
    })
  ];
}
