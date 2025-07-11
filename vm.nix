{pkgs, lib, config, ...}:
let
  targets = [ "x86_64-linux" "i686-linux" "armv5tel-linux" "mipsel-linux" ];
  glibcs = builtins.listToAttrs (builtins.map(t: { name = t; value = (import pkgs.path { inherit (pkgs.stdenv) system; crossSystem = t; }).glibc; }) targets);
  nixify = pkgs.writeShellScriptBin "nixify" ''
    if [[ "$#" -ne 1 ]]; then
        echo "usage: $0 <file>"
        exit 1
    fi
    bin=$1

    case "''${platform:=$(${lib.getExe pkgs.file} "$bin")}" in
        *ARM,\ EABI5*) glibc=${glibcs.armv5tel-linux} ;;
        *x86-64*) glibc=${glibcs.x86_64-linux} ;;
        *80?86*) glibc=${glibcs.i686-linux} ;;
        *MIPS32*) glibc=${glibcs.mipsel-linux} ;;
        *) echo "can't patch $bin:\n$platform"; exit 1 ;;
    esac
    ld=$(${lib.getExe pkgs.patchelf} --print-interpreter "$bin")
    ${lib.getExe pkgs.patchelf} --set-interpreter "$glibc/lib/''${ld##*/}" "$bin"
  '';
  xenu-run = pkgs.writeShellScriptBin "xenu" ''
    if [[ "$#" -eq 1 ]]; then
        bin=$1
    elif [[ "$#" -eq 2 ]]; then
        bin=$2
        debug=1
        if [[ "$1" != "-g" ]]; then
            echo "usage: $0 [-g] <file>"
            exit 1
        fi
    else
        echo "usage: $0 [-g] <file>"
        exit 1
    fi

    if [[ -w "$bin" ]]; then
        ${lib.getExe nixify} "$bin"
    fi

    case "''${platform:=$(${lib.getExe pkgs.file} "$bin")}" in
        *ARM,\ EABI5*) arch=arm ;;
        *x86-64*) arch=x86_64 ;;
        *80?86*) arch=i386 ;;
        *MIPS32*) arch=mipsel ;;
        *) echo "unsupported platform for $bin:\n$platform"; exit 1 ;;
    esac

    socat VSOCK-LISTEN:1338,reuseaddr TCP:localhost:1338 2>/dev/null &
    trap "kill $! &>/dev/null; exit" INT TERM
    if tty -s ; then
        pipe='-'
    else
        pipe='VSOCK-LISTEN:1337,reuseaddr'
    fi
    socat "$pipe" EXEC:"qemu-$arch ''${debug+ -g 1338} $bin",nofork,pty,stderr 2>/dev/null
  '';
in

{
  system.stateVersion = "23.11";

  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = true;

  services.getty.autologinUser = "pwny";
  services.getty.extraArgs = ["-i"];
  users.users.pwny.isNormalUser = true;

  users.users.pwny.extraGroups = ["wheel"];
  security.sudo.wheelNeedsPassword = false;

  nix.nixPath = [ "nixpkgs=${pkgs.path}" ];
  nix.channel.enable = true;
  nix.settings.experimental-features = "nix-command flakes";

  programs.bash.shellInit = ''
    cd /tmp/shared

    IFS=, read -a argv <<<$(sed -nE 's/.*xenu-run-args=(\S+).*/\1/p' /proc/cmdline)
    "''${argv[@]}"
  '';
  environment.etc.bash_logout.text = ''
    sudo poweroff --no-wall
  '';

  environment.systemPackages = with pkgs; [
    vim
    git
    file
    patchelf
    fd
    qemu-user
    socat

    nixify
    xenu-run
  ];

  system.activationScripts.bins = lib.stringAfter [ "binsh" ] ''
    ln -sfn "${pkgs.coreutils}/bin/cat" /bin/cat
    ln -sfn "${pkgs.coreutils}/bin/ls" /bin/ls
  '';

  virtualisation.vmVariant.virtualisation.graphics = false;
  virtualisation.vmVariant.virtualisation.host.pkgs = pkgs;
  documentation.doc.enable = false;

  virtualisation.vmVariant.virtualisation.rosetta.enable = true;

  # needed for gdb
  boot.kernel.sysctl = {
    "kernel.yama.ptrace_scope" = 0;
  };

  boot.initrd.availableKernelModules = [ "virtiofs" ];

  # qemu-vm.nix hardcodes the sharedDirectories as 9p; we need them to be virtiofs.
  virtualisation.vmVariant.virtualisation.fileSystems = lib.mkMerge [
    (let
      mkSharedDir = tag: share:
        {
          name = share.target;
          value = lib.mkForce {
            device = tag;
            fsType = "virtiofs";
            neededForBoot = true;
            options = lib.mkIf false [ "dax" ]; # experimental DMA in upstream, apple probably doesn't support it though
          };
        };
    in
      lib.mapAttrs' mkSharedDir config.virtualisation.vmVariant.virtualisation.sharedDirectories)

    # this shouldn't be necessary, and yet it is.
    { "/run/rosetta" = {
        device = "rosetta";
        fsType = "virtiofs";
      }; }
  ];

  # Evil, evil hack! Basically impossible to remove stuff from another module's attrset...
  # There's really no point to the xchg shared directory; it's a holdover from ages ago.
  virtualisation.vmVariant.virtualisation.sharedDirectories = lib.mkForce {
    nix-store = lib.mkIf config.virtualisation.vmVariant.virtualisation.mountHostNixStore {
      source = builtins.storeDir;
      target = "/nix/.ro-store";
      securityModel = "none";
    };
    shared = {
      source = ''"''${SHARED_DIR:-$TMPDIR/xchg}"'';
      target = "/tmp/shared";
      securityModel = "none";
    };
    certs = lib.mkIf config.virtualisation.vmVariant.virtualisation.useHostCerts {
      source = ''"$TMPDIR"/certs'';
      target = "/etc/ssl/certs";
      securityModel = "none";
    };
  };

  # tmpfs too small for building e.g. glibc, could change if you don't care about using nix-shell in guest
  # virtualisation.vmVariant.virtualisation.writableStoreUseTmpfs = false;
}
