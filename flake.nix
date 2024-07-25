{
  description = "*Gyururururururu*";

  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs.url = "github:feyorsh/nixpkgs/sage-darwin";
    fyshpkgs.url = "github:feyorsh/fyshpkgs";
    # xenu.url = "github:Feyorsh/xenu/main";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs@{ self, nixpkgs, fyshpkgs, flake-utils, ... }:
    # eventually, I might want to include linux
    flake-utils.lib.eachSystem [ "aarch64-linux" "aarch64-darwin" ] (system:
      let pkgs = import nixpkgs {
            inherit system;
            overlays = [ fyshpkgs.overlay.${system} ];
            config.allowUnfree = true;
          };
          # ugh ok so *in theory* host and target packages can peacefully coexist  with .__splicedPackages, but tbh it's a lot of trial and error and a pain in the ass.
          # hopefully splitting them up like this makes it easier to say e.g. `my-pkgs`.gdb and you can include multiple gdbs. This seems much more flexible.
          pkgs-x86 = (import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            # crossSystem = { system = "x86_64-linux"; };
            crossSystem = "x86_64-linux";
          }).__splicedPackages;
          inherit (nixpkgs) lib;
          # FIXME I don't know of a way to override vars in a let binding...
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
            packages = [
              (python.withPackages(ps: with ps; [
                angr
              ]))
              radare2
              ghidra
              binary-ninja-dev
            ];
          };
          # probably can't merge shells with different pkgs? we'll see
          all = with pkgs; mkShell {
            inputsFrom = with lib.attrsets; mapAttrsToList (n: v: optionalAttrs (!builtins.elem n [ "default" "all" ]) v) self.outputs.devShells.${system};
          };
          default = crypto;
        };
      });
}
