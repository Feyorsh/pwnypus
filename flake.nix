{
  description = "*Gyururururururu*";

  inputs = {
    # be careful when updating flakes; cross gdb/linux takes ~1 hour to build
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    xenu = {
      url = "github:Feyorsh/xenu";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fyshpkgs = {
      url = "github:Feyorsh/fyshpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs@{ self, nixpkgs, fyshpkgs, flake-utils, ... }:
    let
      inherit (nixpkgs) lib;

      unfree = true # (import nixpkgs { inherit system; }).config.allowUnfree
               || builtins.getEnv "PWNYPUS_ALLOW_UNFREE" == "1";
      unfree-filter = ps: let
        free = lib.lists.partition (l: !(lib.attrsets.attrByPath [ "meta" "unfree" ] false l)) ps;
        ws = lib.strings.concatStringsSep ", " (lib.lists.forEach free.wrong (p: p.name));
        pns = if builtins.length free.wrong == 1 then " ${ws} is" else "s ${ws} are";
      in
        lib.warnIfNot (unfree || free.wrong == []) "pacakge${pns} unfree and won't be evaluated (set PWNYPUS_ALLOW_UNFREE=1 to allow)" free.right;
      # shell-filter = lib.attrsets.mapAttrs (_: v: lib.attrsets.updateManyAttrsByPath [ { path = [ "" ]; update = unfree-filter; } ] v);
    in {
      darwinModules.chmodbpf = import ./chmodbpf.nix;
      darwinModules.xquartz = import ./xquartz.nix;
    } // (flake-utils.lib.eachSystem [ "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ fyshpkgs.overlay.${system} ];
          config.allowUnfree = true;
        };
        # ugh ok so *in theory* host and target packages can peacefully coexist  with .__splicedPackages, but tbh it's a lot of trial and error and a pain in the ass.
        # hopefully splitting them up like this makes it easier to say e.g. `my-pkgs`.gdb and you can include multiple gdbs. This seems much more flexible.
        pkgs-x86 = (import nixpkgs {
          inherit system;
          crossSystem = "x86_64-linux";
          config.allowUnfree = true;
        }).__splicedPackages;

        python = pkgs.python311;
      in {
        packages = rec { };

        devShells = rec {
          crypto = with pkgs; mkShell {
            packages = [
              (python3.buildEnv.override {
                extraLibs = with python3Packages; [
                  sage.lib
                  pwntools
                  pycryptodome
                  z3-solver
                ];
              })
            ];
          };

          pwn = let
            # this arrangement is a bit fragile, and I'll tell you why:
            # we want to debug e.g. x86_64-linux (target) binaries from an aarch64-darwin (host) machine
            # gdb itself falls into the autoconf camp, so we just build it for targetPlatform == x86 != aarch64
            # but the python ecosystem for plugins (capstone, unicorn, checksec, pyelftools),
            # even though designed for x86, are cross platform by nature.
            # so I only override the platform for bintools and gdb---nothing wrong with this in theory.
            # *however*, usage of gdb in nixpkgs is not designed with this in mind. caveat emptor.
            pkgsCross = pkgs-x86;
            prefix = "${pkgsCross.stdenv.targetPlatform.config}-";
            gdb = pkgsCross.buildPackages.gdb;
            gdb' = pkgs.runCommand "gdb-cross" { nativeBuildInputs = [ ]; }
            ''
              mkdir -p $out/bin
              ln -s ${gdb}/bin/${prefix}gdb $out/bin/gdb
            '';
            readelf' = pkgs.runCommand "readelf-cross" { nativeBuildInputs = [ ]; }
            ''
              mkdir -p $out/bin
              ln -s ${pkgsCross.buildPackages.bintools-unwrapped}/bin/${prefix}readelf $out/bin/readelf
            '';

            # currently marked as broken
            pwndbg = (pkgs.pwndbg.override {
              gdb = gdb';
            }).overrideAttrs {
              meta.broken = pkgsCross.stdenv.targetPlatform.system == "aarch64-darwin";
            };
            gef = (pkgs.gef.override {
              gdb = gdb';
              bintools-unwrapped = readelf';
            }).overrideAttrs {
              meta.broken = pkgsCross.stdenv.targetPlatform.system == "aarch64-darwin";
            };
          in pkgs.mkShell {
            packages = [
              gdb
              pwndbg
              gef
            ];
          };

          rev = with pkgs; mkShell {
            packages = unfree-filter [
              (python.withPackages(ps: with ps; [
                # angr    # waiting on upstream update to unicorn 2.1.1
                z3-solver
              ]))
              radare2
              ghidra
              binary-ninja
            ];
          };

          web = with pkgs; mkShell {
            packages = unfree-filter [
              nodejs
              # burpsuite
              wireshark

              curl
              nmap
              thc-hydra
              # wfuzz fixed in nixpkgs
              gobuster
              sqlmap
              nikto
            ];
          };

          # probably can't merge shells with different pkgs? we'll see
          all = with pkgs; mkShell {
            inputsFrom = with lib.attrsets; mapAttrsToList (n: v: optionalAttrs (!builtins.elem n [ "default" "all" ]) v) self.outputs.devShells.${system};
          };
          default = crypto;
        };
      }));
}
