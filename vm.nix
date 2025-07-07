{pkgs, lib, config, ...}:
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

  programs.bash.shellInit = let
    targets = [ "x86_64-linux" "i686-linux" "armv5tel-linux" "mipsel-linux" ];
    glibcs = builtins.listToAttrs (builtins.map(t: { name = t; value = (import pkgs.path { inherit (pkgs.stdenv) system; crossSystem = t; }).glibc; }) targets);
  in ''
    trap "kill 0" SIGINT SIGTERM EXIT

    cd /tmp/shared

    if [[ "" != "''${bin:=$(sed -nE 's/.*fysh-binary-to-run=(\S+).*/\1/p' /proc/cmdline)}" ]]; then
       case "''${platform:=$(${lib.getExe pkgs.file} "$bin")}" in
         *ARM,\ EABI5*) arch=arm; glibc=${glibcs.armv5tel-linux} ;;
         *x86-64*) arch=x86_64; glibc=${glibcs.x86_64-linux} ;;
         *80?86*) arch=i386; glibc=${glibcs.i686-linux} ;;
         *MIPS32*) arch=mipsel; glibc=${glibcs.mipsel-linux} ;;
         *) echo "can't run $bin:\n$platform"; exit 1 ;;
        esac
        ld=$(${lib.getExe pkgs.patchelf} --print-interpreter "$bin")
        ${lib.getExe pkgs.patchelf} --set-interpreter "$glibc/lib/''${ld##*/}" "$bin"
        if [[ "" != "''$(sed -nE 's/.*(fysh-enable-gdb).*/\1/p' /proc/cmdline)" ]]; then
            echo "running $bin with GDB..."
            (socat VSOCK-LISTEN:1337 TCP:localhost:1338 &)
            sleep 1
            "qemu-$arch" -g 1338 "./$bin"
        else
            echo "running $bin..."
            socat VSOCK-LISTEN:1337,fork,reuseaddr EXEC:"qemu-$arch ./$bin"
        fi
    fi
  '';
  environment.etc.bash_logout.text = ''
    sudo poweroff
  '';

  environment.systemPackages = with pkgs; [
    vim
    git
    file
    patchelf
    fd
    qemu-user
    socat
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
