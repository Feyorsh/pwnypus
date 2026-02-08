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

  environment.etc.bash_logout.text = ''
    if [[ $SHLVL -eq 1 ]]; then
        sudo poweroff --no-wall
    fi
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

  # options.xenuTargets = lib.mkOption {
  #   type = lib.types.list;
  #   default = [];
  # };
}
