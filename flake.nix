{
  description = "*Gyururururururu*";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    fyshpkgs.url = "github:feyorsh/fyshpkgs";
    # xenu.url = "github:Feyorsh/xenu/main";
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
    } // (flake-utils.lib.eachSystem [ "aarch64-linux" "aarch64-darwin" ] (system:
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
            packages = let
              sagemath = sage.override {
                extraPythonPackages = ps: with ps; [
                  pwntools
                  pycryptodome
                  z3-solver
                ]; };
            in [
              sagemath
              (runCommand "python3" {} ''
                 mkdir -p $out/bin
                 ln -s ${lib.getBin sagemath.with-env}/bin/sage-python $out/bin/python3
               '')
            ];
          };
          pwn = with pkgs-x86; mkShell {
            packages = [
              gdb
            ];
          };
          rev = with pkgs; mkShell {
            packages = unfree-filter [
              (python.withPackages(ps: with ps; [
                angr
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
