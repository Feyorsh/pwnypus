{ lib, pkgs, config, ... }:
with lib;                      
let
  cfg = config.security.chmodbpf;
in {
  options.security.chmodbpf = {
    enable = mkEnableOption "ChmodBPF";
    maxDevices = mkOption {
      type = types.unsigned;
      default = 256;
      description = ''
        Number of BPF devices that will be created.

        This is bound by debug.bpf_maxdevices.
      '';
    };
    group = mkOption {
      type = types.str;
      default = "access_bpf";
      description = ''
        The group's name.
      '';
    };
    writable = mkOption {
      type = types.boolean;
      default = true;
      description = ''
        Whether the BPF access group can send raw packets (in addition to capturing them).
      '';
    };
  };

  config = mkIf cfg.enable {
    users = {
      groups."${cfg.group}" = {
        gid = mkDefault 555;
        description = "User group with permissions for /dev/bpf*";
      };
    };

    launchd.daemons.chmodbpf.serviceConfig = {
      Program = pkgs.writeShellScriptBin "ChmodBPF" ''
        FORCE_CREATE_BPF_MAX=${cfg.maxDevices}
        
        SYSCTL_MAX=$( sysctl -n debug.bpf_maxdevices )
        if [ "$FORCE_CREATE_BPF_MAX" -gt "$SYSCTL_MAX" ] ; then
	        FORCE_CREATE_BPF_MAX=$SYSCTL_MAX
        fi
        
        syslog -s -l notice "ChmodBPF: Forcing creation and setting permissions for /dev/bpf0-$(( FORCE_CREATE_BPF_MAX - 1))"
        
        CUR_DEV=0
        while [ "$CUR_DEV" -lt "$FORCE_CREATE_BPF_MAX" ] ; do
	        # Try to do the minimum necessary to trigger the next device.
	        read -r -n 0 < /dev/bpf$CUR_DEV > /dev/null 2>&1
	        CUR_DEV=$(( CUR_DEV + 1 ))
        done
        
        chgrp ${cfg.group} /dev/bpf*
        chmod g+r${lib.optionalString cfg.writeable "w"} /dev/bpf*
      '';
      RunAtLoad = true;
    };
  };
}
