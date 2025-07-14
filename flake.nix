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
          xenu = {
            type = "app";
            program = lib.getExe self.packages.${system}.xenu-vm;
          };
        };

        packages = {
          xenu-vm = let
            script = { cores, memory, kernel, initrd, cmdline, vmImgSize }: pkgs.writeShellScriptBin "xenu-vm" ''
              function find-up {
                  path=$(pwd)
                  while [[ "$path" != "" && ! -e "$path/$1" ]]; do
                      path=''${path%/*}
                  done
                  [[ ! -e "$path/$1" ]] && echo "$path"
              }

              XENU_STDIO_PORT=''${XENU_STDIO_PORT:-1337}
              XENU_DEBUG_PORT=''${XENU_DEBUG_PORT:-1338}
              if [[ "$XENU_DEBUG_PORT" == "$XENU_STDIO_PORT" ]]; then
                  echo "\$XENU_STDIO_PORT and \$XENU_DEBUG_PORT cannot be the same (both are $XENU_STDIO_PORT)"
                  exit 1
              fi

              XENU_DIR=$(find-up ''${XENU_DIR:-.xenu})
              if [[ "$XENU_DIR" == "" ]]; then
                  XENU_DIR=".xenu"
                  mkdir -p $XENU_DIR
              elif [[ ! -d "$XENU_DIR" ]]; then
                  echo "error: $XENU_DIR is not a directory"
                  exit 1
              fi

              VM_IMAGE="$XENU_DIR/vm.raw" || test -z "$VM_IMAGE"
              if test -n "$VM_IMAGE" && ! test -e "$VM_IMAGE"; then
                  ${pkgs.qemu-utils}/bin/qemu-img create -f raw $VM_IMAGE "${toString vmImgSize}M"
                  ${pkgs.e2fsprogs}/bin/mkfs.ext4 -L nixos $VM_IMAGE
              fi

              rm -f $XENU_DIR/*.sock
              socat TCP-LISTEN:$XENU_STDIO_PORT,fork,reuseaddr UNIX-CONNECT:$XENU_DIR/stdio.sock 2>/dev/null &
              socat TCP-LISTEN:$XENU_DEBUG_PORT,fork,reuseaddr UNIX-CONNECT:$XENU_DIR/debug.sock 2>/dev/null &

              QEMU_KERNEL_PARAMS+=" xenu-run-args=''$@"

              trap 'stty intr ^C; kill $(jobs -p)' INT TERM EXIT
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
                --device virtio-blk,path=$VM_IMAGE \
                --device virtio-fs,sharedDir=/nix/store/,mountTag=nix-store \
                --device virtio-fs,sharedDir=./,mountTag=shared \
                --device virtio-vsock,port=1337,socketURL=$(realpath $XENU_DIR/stdio.sock),connect \
                --device virtio-vsock,port=1338,socketURL=$(realpath $XENU_DIR/debug.sock),connect \
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
            x86_64-pkgs = pkgs.pkgsCross.gnu64;
            binutils-multiarch = pkgs.binutils-unwrapped.override {
              withAllTargets = true;
            };
            gef' = (pkgs.gef.override {
              bintools-unwrapped = binutils-multiarch;
            });
          in with pkgs; mkShell {
            packages = unfreeFilter [
              patchelf
              x86_64-pkgs.buildPackages.bintools-unwrapped
              binutils-multiarch

              gdb
              gef'
              pwndbg.packages.${system}.pwndbg
              radare2

              (python312.withPackages(ps: with ps; [
                pwntools
                ropper
              ]))
              one_gadget

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
