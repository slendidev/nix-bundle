{
  nixpkgs ? import <nixpkgs> { },
}:

with nixpkgs;

rec {
  toStorePath =
    target:
    # If a store path has been given but is not a derivation, add the missing context
    # to it so it will be propagated properly as a build input.
    if !(lib.isDerivation target) && lib.isStorePath target then
      let
        path = toString target;
      in
      builtins.appendContext path {
        "${path}" = {
          path = true;
        };
      }
    # Otherwise, add to the store. This takes care of appending the store path
    # in the context automatically.
    else
      "${target}";

  arx =
    {
      drvToBundle,
      archive,
      startup,
    }:
    stdenv.mkDerivation {
      name = if drvToBundle != null then "${drvToBundle.pname}-arx" else "arx";
      passthru = {
        inherit drvToBundle;
      };
      buildCommand = ''
        # tmpdir has a additional `/` in the beginning to work around `QualifiedPath` checking for `|/|./|../|`
        ${haskellPackages.arx}/bin/arx tmpx \
          --tmpdir '/$HOME/.cache' \
          --shared \
          -rm! ${archive} \
          -o $out // ${startup}
        sed -i '1a export BUNDLE_PWD="''${BUNDLE_PWD:-$PWD}"' "$out"
        chmod +x $out
      '';
    };

  maketar =
    { targets }:
    let
      closure = closureInfo { rootPaths = targets; };
    in
    stdenv.mkDerivation {
      name = "maketar";
      buildInputs = [ perl ];
      exportReferencesGraph = map (x: [
        ("closure-" + baseNameOf x)
        x
      ]) targets;
      buildCommand = ''
        storePaths=$(cat ${closure}/store-paths)

        # https://reproducible-builds.org/docs/archives
        tar -cf - \
          --owner=0 --group=0 --mode=u+rw,uga+r \
          --hard-dereference \
          --mtime="@$SOURCE_DATE_EPOCH" \
          --format=gnu \
          --sort=name \
          $storePaths | xz -9 -T $(nproc) > $out
      '';
    };

  proot' = proot.overrideAttrs (_: {
    # hack to use when /nix/store is not available
    postFixup = ''
      exe=$out/bin/proot
      patchelf \
        --set-interpreter .$(patchelf --print-interpreter $exe) \
        --set-rpath $(patchelf --print-rpath $exe | sed 's|/nix/store/|./nix/store/|g') \
        $exe
    '';
  });

  makebootstrap =
    {
      targets,
      startup,
      drvToBundle ? null,
    }:
    arx {
      inherit drvToBundle startup;
      archive = maketar {
        inherit targets;
      };
    };

  makeStartup =
    {
      target,
      nixUserChrootFlags,
      proot,
      run,
    }:
    writeScript "startup" ''
      #!/bin/sh
      .${proot}/bin/proot -b ./nix:/nix -R / -w "''${BUNDLE_PWD}" ${target}${run} $@
    '';

  nix-bootstrap =
    {
      target,
      extraTargets ? [ ],
      run,
      proot ? proot',
      nixUserChrootFlags ? "",
    }:
    let
      script = makeStartup {
        inherit
          target
          nixUserChrootFlags
          proot
          run
          ;
      };
    in
    makebootstrap {
      startup = ".${script} '\"$@\"'";
      targets = [ "${script}" ] ++ extraTargets;
    };

  nix-bootstrap-nix =
    {
      target,
      run,
      extraTargets ? [ ],
    }:
    nix-bootstrap-path {
      inherit target run;
      extraTargets = [
        gnutar
        bzip2
        xz
        gzip
        coreutils
        bash
      ]
      ++ extraTargets;
    };

  # special case adding path to the environment before launch
  nix-bootstrap-path =
    let
      proot'' =
        targets:
        proot'.overrideDerivation (o: {
          # TODO: not sure yet what we need to do here
        });
    in
    {
      target,
      extraTargets ? [ ],
      run,
    }:
    nix-bootstrap {
      inherit target extraTargets run;
      proot = proot'' extraTargets;
    };
}
