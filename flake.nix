{
  description = "*Gyururururururu*";

  inputs = {
    # be careful when updating flakes; cross gdb/linux takes ~1 hour to build
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    fyshpkgs = {
      url = "github:Feyorsh/fyshpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pwndbg.url = "github:pwndbg/pwndbg";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs@{ self, nixpkgs, fyshpkgs, pwndbg, flake-utils, ... }:
    let
      inherit (nixpkgs) lib;

      allowUnfree = false # (import nixpkgs { inherit system; }).config.allowUnfree
               || builtins.getEnv "PWNYPUS_ALLOW_UNFREE" == "1";
      unfreeFilter = ps: let
        freePkgs = lib.lists.partition (l: !(lib.attrsets.attrByPath [ "meta" "unfree" ] false l)) ps;
        ws = lib.strings.concatStringsSep ", " (lib.lists.forEach freePkgs.wrong (p: p.name));
        pns = if builtins.length freePkgs.wrong == 1 then " ${ws} is" else "s ${ws} are";
      in
        if !(allowUnfree || freePkgs.wrong == [])
        then lib.warn "pacakge${pns} unfree and won't be evaluated (set PWNYPUS_ALLOW_UNFREE=1 to allow)" freePkgs.right
        else ps;
    in {
      darwinModules.chmodbpf = import ./chmodbpf.nix;
      darwinModules.xquartz = import ./xquartz.nix;

      nixosModules.vm = ./vm.nix;

      nixosConfigurations.linuxVM = lib.nixosSystem {
        system = "aarch64-linux";
        modules = [ self.nixosModules.vm ];
      };
    } // (flake-utils.lib.eachSystem [ "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ fyshpkgs.overlay.${system} ];
          config.allowUnfree = true;
        };
      in {
        apps = {
          vm = {
            type = "app";
            program = lib.getExe self.packages.${system}.run-vm;
          };
        };

        packages = {
          run-vm = let
            script = { cores, memory, kernel, initrd, cmdline, vmImgSize }: pkgs.writeShellScriptBin "run-vm" ''
              trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

              VM_IMAGE=$(readlink -f "''${VM_IMAGE:-./vm.raw}") || test -z "$VM_IMAGE"
              if test -n "$VM_IMAGE" && ! test -e "$VM_IMAGE"; then
                  ${pkgs.qemu-utils}/bin/qemu-img create -f raw vm.raw "${toString vmImgSize}M"
                  ${pkgs.e2fsprogs}/bin/mkfs.ext4 -L nixos vm.raw
              fi

              rm -f ./vm.sock

              if [[ "$1" == "-g" ]]; then
                  QEMU_KERNEL_PARAMS+=" fysh-enable-gdb"
              fi
              if [[ $# -gt 0 ]]; then
                  QEMU_KERNEL_PARAMS+=" fysh-binary-to-run=''${@: -1}"
                  (socat TCP-LISTEN:1337,fork,reuseaddr UNIX-CONNECT:./vm.sock &)
              fi


              trap 'stty intr ^C' SIGINT SIGTERM EXIT
              stty intr ^]

              ${lib.getExe pkgs.vfkit} \
                --log-level 'error' \
                --cpus ${toString cores} \
                --memory ${toString memory} \
                --kernel ${kernel} \
                --initrd ${initrd} \
                --kernel-cmdline ${cmdline} \
                --device rosetta,mountTag=rosetta \
                --device virtio-serial,stdio \
                --device virtio-net,nat \
                --device virtio-blk,path=./vm.raw \
                --device virtio-fs,sharedDir=/nix/store/,mountTag=nix-store \
                --device virtio-fs,sharedDir=./,mountTag=shared \
                --device virtio-vsock,port=1337,socketURL=$PWD/vm.sock,connect \
                --device virtio-rng

                # TODO
                # add rosetta mount options
                # --device virtio-balloon
            '';
            linux = self.nixosConfigurations.linuxVM.config.system.build.vm;
            kernel_cmdline = lib.removePrefix "-append " (lib.findFirst (lib.hasPrefix "-append ") null self.nixosConfigurations.linuxVM.config.virtualisation.vmVariant.virtualisation.qemu.options);
          in
            lib.makeOverridable script {
              cores = 1;
              memory = 1024; # MiB
              kernel = "${linux}/system/kernel";
              initrd = "${linux}/system/initrd";
              cmdline = kernel_cmdline;
              vmImgSize = 5120;
            };
        };

        devShells = rec {
          crypto = with pkgs; mkShell {
            packages = [
              (python312.buildEnv.override {
                extraLibs = with python312Packages; [
                  sage.lib
                  pwntools
                  pycryptodome
                  z3-solver
                ];
              })
            ];
          };

          pwn = let
            pkgsCross = pkgs.pkgsCross.gnu64;
            readelf' = pkgs.runCommand "readelf-cross" { nativeBuildInputs = [ ]; }
            ''

              mkdir -p $out/bin
              ln -s ${pkgsCross.buildPackages.bintools-unwrapped}/bin/${pkgsCross.stdenv.targetPlatform.config}readelf $out/bin/readelf
            '';

            gef' = (pkgs.gef.override {
              bintools-unwrapped = readelf';
            });
          in with pkgs; mkShell {
            packages = [
              gdb
              gef'
              pwndbg.packages.${system}.pwndbg
              radare2

              (python312.withPackages(ps: with ps; [
                pwntools
              ]))

              ghidra
              binary-ninja
              ida-pro
            ];
          };

          rev = with pkgs; mkShell {
            packages = unfreeFilter [
              (python12.withPackages(ps: with ps; [
                # angr    # waiting on upstream update to unicorn 2.1.1
                z3-solver
                pwntools
              ]))
              radare2
              ghidra
              binary-ninja
              ida-pro
            ];
          };

          web = with pkgs; mkShell {
            packages = unfreeFilter [
              nodejs
              # burpsuite
              wireshark

              curl
              nmap
              thc-hydra
              # wfuzz # transient closure depends on pyobjc; fix in nixpkgs
              gobuster
              sqlmap
              nikto

              postman
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
