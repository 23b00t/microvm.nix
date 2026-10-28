# Builds a read-only /nix/store image (erofs or squashfs) from the
# closure of `contents`. Several guests can share one image when
# `contents` is the union of their `microvm.storeDiskContents`.
{ pkgs
, lib ? pkgs.lib
, type ? "erofs"
, erofsFlags ? [ "-zlz4hc" ]
, squashfsFlags ? [ "-c" "zstd" "-j" "$NIX_BUILD_CORES" ]
, contents
}:

let
  erofs-utils =
    # Is deduplication option specified?
    if lib.elem "-Ededupe" erofsFlags
    then
      # If specified, stick to the single-threaded erofs-utils
      # to not scare anyone with warning messages. mkfs.erofs
      # has no multi-threaded -Ededupe, so it forces
      # single-threaded compression.
      pkgs.buildPackages.erofs-utils
    else
      # Otherwise rebuild mkfs.erofs with multi-threading.
      pkgs.buildPackages.erofs-utils.overrideAttrs (attrs: {
        configureFlags = attrs.configureFlags ++ [
          "--enable-multithreading"
        ];
      });

  erofsFlags' = builtins.concatStringsSep " " erofsFlags;
  squashfsFlags' = builtins.concatStringsSep " " squashfsFlags;

  mkfsCommand =
    {
      squashfs = "gensquashfs ${squashfsFlags'} -D store --all-root -q $out";
      erofs = "mkfs.erofs ${erofsFlags'} -T 0 --all-root -L nix-store --mount-point=/nix/store $out store";
    }.${type};

  checkProbeCommand = lib.optionalString (type == "erofs") /* bash */ ''
    echo Checking that the store disk is identified as erofs with LABEL=nix-store
    probe=$(blkid -p -o udev "$out")
    if ! grep -qx 'ID_FS_TYPE=erofs' <<<"$probe" ||
       ! grep -qx 'ID_FS_LABEL=nix-store' <<<"$probe"; then
      cat >&2 <<EOF
ERROR: blkid does not identify the store disk as erofs with LABEL=nix-store.

The guest mounts this disk through /dev/disk/by-label/nix-store,
so a failed probe leaves the VM without a nix store and drops it into the emergency shell,
where no TTY is attached.

This can be fixed by changing the configuration, eg: adding a new package

blkid reported:
EOF
      printf '%s\n' "''${probe:-<no output>}" | sed 's/^/  /' >&2
      exit 1
    fi
  '';

  writeClosure = pkgs.writeClosure or pkgs.writeReferencesToFile;

  storeDiskContents = writeClosure contents;

in
pkgs.buildPackages.runCommandLocal "microvm-store-disk.${type}" {
  nativeBuildInputs = [
    pkgs.buildPackages.time
    pkgs.buildPackages.bubblewrap
    pkgs.buildPackages.util-linux
    {
      squashfs = pkgs.buildPackages.squashfs-tools-ng;
      erofs = erofs-utils;
    }.${type}
  ];
  __structuredAttrs = true;
  unsafeDiscardReferences.out = true;
} ''
  mkdir store
  BWRAP_ARGS="--dev-bind / / --chdir $(pwd)"
  for d in $(sort -u ${storeDiskContents}); do
    BWRAP_ARGS="$BWRAP_ARGS --ro-bind $d $(pwd)/store/$(basename $d)"
  done

  echo Creating a ${type}
  bwrap $BWRAP_ARGS -- time ${mkfsCommand} || \
    (
      echo "Bubblewrap failed. Falling back to copying...">&2
      cp -a $(sort -u ${storeDiskContents}) store/
      time ${mkfsCommand}
    )

  ${checkProbeCommand}
''
