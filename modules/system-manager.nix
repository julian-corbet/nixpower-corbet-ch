#
# nixpower's sleep stance and native package intent for system-manager hosts, mirroring this
# repo's own NixOS module (`modules/nixos.nix`).
#
# WHY A SECOND IMPLEMENTATION AND NOT AN IMPORT: the NixOS module expresses masking through
# `systemd.units.<name>.enable = false`, which system-manager does not implement. The OPTION SURFACE
# is deliberately identical (`nixpower.sleep.{allowed,reason}`) so a host reads the same on
# either manager and nobody has to remember which kind of box they are looking at. Only the
# mechanism differs: tmpfiles `L+` symlinks to /dev/null, which is what `systemctl mask` does anyway.
#
# Native package intent is deliberately only that: this module publishes package names for the
# host's package reconciler, but never configures a second power controller. TLP remains the
# distro-owned policy engine for CPU, PCIe, runtime-PM, and storage knobs.
#
# WHY THIS EXISTS AT ALL -- a privileged Arch container incident (2026-07-26): a privileged LXC gets
# `lxc.mount.auto = ... sys:rw`, i.e. the HOST's real sysfs, writable. `systemctl suspend` in such a
# container does not suspend the container -- containers cannot suspend -- systemd-sleep writes the
# HOST's /sys/power/state and the physical machine goes down. The host is s2idle-only and its
# RX 6800 has never survived that resume, so an inherited laptop idle default wedged the GPU and
# killed the on-card USB-C controller twice. A container therefore needs the same "must not sleep"
# stance as a host, which is precisely what this module is for.
#
{ config, lib, ... }:
let
  cfg = config.nixpower;
  sleepCfg = cfg.sleep;

  # Both the .targets AND the .service units. Masking only the targets leaves
  # `systemctl start systemd-suspend.service` working, which bypasses them entirely -- found live on
  # a privileged Arch container 2026-07-26 with the targets masked and systemd-suspend.service still reading `static`.
  units = import ../lib/sleep-units.nix { };
  sleepUnits = (map (t: "${t}.target") units.targets) ++ (map (s: "${s}.service") units.services);
in
{
  options.nixpower = {
    sleep = {
      allowed = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this host may enter a system sleep state. `false` masks every sleep target AND the
          corresponding systemd-*.service units, so neither a dependency nor a direct
          `systemctl start systemd-suspend.service` can reach a suspend.

          Masked, not disabled: a masked unit cannot be pulled in as a dependency either.
        '';
      };

      reason = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Required when allowed = false: why this host must not sleep. Asserted, so the mask can never appear without its justification.";
      };

      maskSysfs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Mount a read-only tmpfs over /sys/power, so there is no `state` file to write at all.

          Only meaningful where /sys is the HOST's sysfs rather than this machine's own -- i.e. a
          privileged container. Unit masking above stops everything that goes through systemd; this
          stops a raw `echo mem > /sys/power/state`, which systemd never sees. On a real host this
          would only blind your own kernel's power interface, hence the `false` default.

          Belt and braces: the container boundary should mask it too (an LXC `lxc.mount.entry`), which
          is the stronger guard because it applies before any process in the container runs. This is
          the fallback for a start that somehow lacks it.
        '';
      };
    };

    tlp.enable = lib.mkEnableOption "TLP as this host's distro power-policy engine";

    tlpRdw.enable = lib.mkEnableOption "TLP's Radio Device Wizard";

    powertop.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "powertop: an audit tool for power use and unmanaged knobs. It is never invoked with --auto-tune by nixpower.";
    };

    cpupower.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install cpupower for read-only CPU frequency and policy diagnostics. Its vendor service is
        kept disabled: TLP remains the only component that writes CPU power policy.
      '';
    };

    brightnessctl.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        brightnessctl: set the panel backlight (and any other LED class device) from a script or a
        keybind. Same option name and same meaning as this repo's NixOS module, so a host reads
        identically on either manager -- see that module for the full account of why a backlight
        control belongs to the power layer at all (it is display POWER, on the same
        `/sys/class/backlight` surface every other knob here writes, not desktop furniture) and of
        the removed `hardware.brightnessctl` NixOS option that would otherwise shadow it there.

        THE ONE ENTRY IN THIS MODULE'S PACKAGE INTENT THAT IS NOT A POWER DAEMON OR ITS DIAGNOSTIC,
        and the distinction is worth keeping straight: TLP writes policy the machine then holds,
        powertop and cpupower report on it, and this is a tool a HUMAN drives. It therefore cannot
        race TLP the way a second policy engine would -- there is no `SOUND_POWER_SAVE`-shaped knob
        two components could disagree about, only a value someone asked for. nixpower never invokes
        it; what calls it (a compositor keybind, an OSD daemon, a script) is the host's own business
        and deliberately not this module's.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selected native package names for a system-manager host. This module installs nothing;
        connect the list to the host's package reconciler, for example:

          nixarch.packages.pacman = config.nixpower.archPackages;
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = sleepCfg.allowed || sleepCfg.reason != "";
          message = "nixpower.sleep.allowed = false requires sleep.reason (why this host must not sleep).";
        }
        {
          assertion = !cfg.tlpRdw.enable || cfg.tlp.enable;
          message = "nixpower.tlpRdw.enable requires nixpower.tlp.enable: TLP-RDW is an extension of TLP, not an independent power manager.";
        }
      ];

      nixpower.archPackages = lib.unique (
        lib.optional cfg.tlp.enable "tlp"
        ++ lib.optional cfg.tlpRdw.enable "tlp-rdw"
        ++ lib.optional cfg.powertop.enable "powertop"
        ++ lib.optional cfg.cpupower.enable "cpupower"
        # `brightnessctl`, official-repo upstream Arch (`extra`), so it goes to the pacman half of
        # a consumer's reconciler like every other name here -- verified on two live CachyOS hosts
        # and against archlinux.org, with the AUR carrying nothing by that name.
        ++ lib.optional cfg.brightnessctl.enable "brightnessctl"
      );
    }

    (lib.mkIf cfg.cpupower.enable {
      # Pacman ships this unit disabled; remove an accidental enablement on every switch as well.
      # The package stays available for `cpupower frequency-info`, but it never races TLP by applying
      # /etc/default/cpupower-service.conf at boot.
      systemd.tmpfiles.rules = [ "r /etc/systemd/system/multi-user.target.wants/cpupower.service - - - -" ];
    })

    (lib.mkIf (!sleepCfg.allowed) {
      systemd.tmpfiles.rules = map (u: "L+ /etc/systemd/system/${u} - - - - /dev/null") sleepUnits;

      # logind's idle path is the documented trigger of the privileged Arch container incident above
      # (swayidle ran `systemctl suspend` on a 600 s idle timeout). Masked units already make that a
      # no-op, but a machine told never to sleep should not be arming idle actions in the first place.
      environment.etc."systemd/logind.conf.d/99-nixpower-no-sleep.conf".text = ''
        # Generated by nixpower.sleep.allowed = false
        # Reason: ${sleepCfg.reason}
        [Login]
        IdleAction=ignore
        IdleActionSec=0
        HandleSuspendKey=ignore
        HandleSuspendKeyLongPress=ignore
        HandleHibernateKey=ignore
        HandleHibernateKeyLongPress=ignore
        HandleLidSwitch=ignore
        HandleLidSwitchExternalPower=ignore
        HandleLidSwitchDocked=ignore
      '';
    })

    (lib.mkIf (!sleepCfg.allowed && sleepCfg.maskSysfs) {
      systemd.services.nixpower-mask-sys-power = {
        description = "nixpower: mask /sys/power (${sleepCfg.reason})";
        wantedBy = [ "sysinit.target" ];
        before = [ "sysinit.target" "basic.target" ];
        unitConfig = {
          DefaultDependencies = false;
          # No-op when the container boundary already mounted it -- the two layers must not fight.
          ConditionPathIsMountPoint = "!/sys/power";
          ConditionPathExists = "/sys/power";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "/usr/bin/mount -t tmpfs -o ro,mode=0555,size=4k,nosuid,nodev,noexec tmpfs /sys/power";
          ExecStop = "/usr/bin/umount /sys/power";
        };
      };
    })
  ];
}
