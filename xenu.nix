{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.xenu;
in
{
  options.xenu = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable Xenu, a mashup of pwninit and qemu-system.
      '';
    };
    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "x86_64-linux" ];
    };
  };
  config =
    let
      glibcs = builtins.listToAttrs (
        map (t: {
          name = t;
          value =
            (import pkgs.path {
              inherit (pkgs.stdenv) system;
              crossSystem = t;
            }).glibc;
        }) cfg.targets
      );
      nixify = pkgs.writeShellScriptBin "nixify" ''
        if [[ "$#" -ne 1 ]]; then
            echo "usage: $0 <file>"
            exit 1
        fi
        bin=$1

        case "''${platform:=$(${lib.getExe pkgs.file} "$bin")}" in
            ${lib.optionalString (glibcs ? armv5tel-linux) "*ARM,\ EABI5*) glibc=${glibcs.armv5tel-linux} ;;"}
            ${lib.optionalString (glibcs ? x86_64-linux) "*x86-64*) glibc=${glibcs.x86_64-linux or ""} ;;"}
            ${lib.optionalString (glibcs ? i686-linux) "*80?86*) glibc=${glibcs.i686-linux or ""} ;;"}
            ${lib.optionalString (glibcs ? mipsel-linux) "*MIPS32*) glibc=${glibcs.mipsel-linux or ""} ;;"}
            *) echo "can't patch $bin: $platform"; exit 1 ;;
        esac
        ld=$(${lib.getExe pkgs.patchelf} --print-interpreter "$bin")
        if [[ -n "$glibc" ]]; then
            ${lib.getExe pkgs.patchelf} --set-interpreter "$glibc/lib/''${ld##*/}" "$bin"
        fi
      '';
      xenu-run = pkgs.writeShellScriptBin "xenu" ''
        set -m

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
            *ARM\ aarch64*) arch=aarch64 ;;
            *ARM,\ EABI5*) arch=arm ;;
            *x86-64*) arch=x86_64 ;;
            *80?86*) arch=i386 ;;
            *MIPS32*) arch=mipsel ;;
            *) echo "unsupported platform for $bin: $platform"; exit 1 ;;
        esac

        if [[ -t 0 ]] ; then
            pipe='-'
        else
            pipe='VSOCK-LISTEN:1337,reuseaddr'
        fi
        if [[ -n $debug ]] || [[ "$arch" != "x86_64" ]]; then
            # use qemu-user
            socat "$pipe" EXEC:"qemu-$arch ''${debug+ -g /tmp/xenu-gdb-$$.sock} $bin",nofork,pty,stderr 2>/dev/null &
            socat VSOCK-LISTEN:1338 UNIX-CONNECT:/tmp/xenu-gdb-$$.sock 2>/dev/null &
            trap "kill $! &>/dev/null; rm -rf /tmp/xenu-gdb-$$.sock; exit" INT TERM
            fg %1 >/dev/null
        else
            # use rosetta
            if [[ -n $ROSETTA_DEBUGSERVER_PORT ]]; then
                socat VSOCK-LISTEN:1338,reuseaddr TCP:localhost:$ROSETTA_DEBUGSERVER_PORT,reuseaddr 2>/dev/null &
                trap "kill $! &>/dev/null; exit" INT TERM
                fg %1 >/dev/null
            fi
            socat "$pipe" EXEC:"$(realpath $bin)",nofork,pty,stderr 2>/dev/null
        fi
      '';
    in
    {
      environment.systemPackages = [ xenu-run nixify ];

      programs.bash.shellInit = ''
        cd /tmp/shared

        # get input from a pipe to mark process as non-interactive
        : | eval $(sed -nE 's/.*xenu-run-args=(.*)$/\1/p' /proc/cmdline)
      '';
    };
}
