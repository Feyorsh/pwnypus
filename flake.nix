{
  description = "*Gyururururururu*";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # xenu.url = "github:Feyorsh/xenu/main";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    # eventually, I might want to include another platform
    flake-utils.lib.eachSystem [ "aarch64-darwin" ] (system:
    let pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
    in {
    packages = rec { };
    devShells = {
      crypto = with pkgs; mkShell {
        packages = [
          (python312.withPackages(ps: with ps; [
            pycryptodome
            numpy
          ]))
          # sage
        ];
      };
      default = crypto;
    });
}
