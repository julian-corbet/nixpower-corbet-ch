# modules/nixos.nix
#
# ONE declarative power stance per host.
#
# WHY a module and not more per-host lines: the 2026-07-24 amdgpu incident
# was not caused by a missing knob. Every individual knob on the host
# was set deliberately and correctly, INCLUDING an explicit exclusion keeping
# the RX 6800 complex at power/control=on because D3 resume on desktop-class
# amdgpu is known-glitchy. The box still lost its GPU for a day, because a
# SYSTEM suspend (s2idle) suspends every device regardless of its runtime-PM
# policy -- the per-device exclusion and the system sleep state are two
# different layers, and nothing in the config could express the sentence
# "this host cannot survive a suspend". That sentence is `sleep.allowed`
# below, and the mismatch between the two layers is an explicit warning.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : system sleep policy, PCI/USB/SCSI runtime PM, CPU EPP, PCIe ASPM,
#           SATA ALPM, dirty-writeback interval, device coredumps.
#   NOT   : ATA standby timers for rotational drives -- this repo's own
#           `modules/disk-standby.nix` owns those; they are storage policy that happens
#           to save power, keyed off queue/rotational and the USB exclusion.
#   NOT   : a laptop. On an Arch box driven by system-manager with a pacman-owned TLP, TLP
#           manages EPP, ASPM and spindown itself; pointing this module at the same knobs
#           would be a two-mechanisms-one-knob fight. Laptop power stays TLP's.
#
# Self-contained on purpose: no per-host imports, no reads from a private option namespace.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixpower;

  # PCI IDs are matched as udev ATTR strings ("0x73bf"), not integers.
  #
  # ACTION=="add|bind", not "add" alone. A driver's probe() may re-enable runtime PM
  # for its own device (xhci_hcd calls pm_runtime_allow(), which writes power/control
  # back to "auto") -- and that happens AFTER the add event udev reacted to, so an
  # add-only rule silently loses the race and the device is left at "auto".
  # Demonstrated on the host 2026-07-26: a PCI remove+rescan of the RX 6800's
  # USB-C function came back at "auto" despite this rule matching, runtime-suspended
  # ~7 s later, and the controller died on the D3 resume. "bind" fires after the
  # driver has had its say, so the pin is re-asserted where it actually sticks.
  #
  # "bind" IS STILL NOT ENOUGH FOR EVERY DRIVER, which is why nixpower-runtime-pm-assert
  # exists below. The bind uevent is emitted when probe() RETURNS -- a driver that finishes
  # its setup asynchronously after that point gets the last word anyway. snd_hda_intel is
  # exactly that shape: with power_save non-zero it calls pm_runtime_allow() from its
  # deferred probe continuation, well after bind, and the device lands back at "auto".
  # Observed 2026-07-29 on an AMD Navi HDMI/DP audio function (0x1002:0xab28), which sat at
  # "auto" and runtime-suspended across every boot while this rule matched it correctly and
  # the verifier reported a failure it could not explain. There is no udev action that fires
  # "after the driver is really done", so the pin has to be re-asserted once from a unit
  # ordered late in the boot. A write at that point sticks -- confirmed by hand on the same
  # device: still "on", still runtime-active, long after the driver had settled.
  keepPoweredRules = lib.concatMapStringsSep "\n" (d: ''
    # ${d.reason}
    ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="${d.vendor}", ATTR{device}=="${d.device}", ATTR{power/control}="on"'') cfg.runtimePm.keepPowered;

  # Both lists come from lib/sleep-units.nix, shared with the system-manager backend so the two
  # cannot drift -- see that file for why it exists.
  sleepUnits = import ../lib/sleep-units.nix { };
  sleepTargets = sleepUnits.targets;

  sleepServices = sleepUnits.services;
in
{
  options.nixpower = {
    enable = lib.mkEnableOption "nixpower: one declarative power stance for this host";

    sleep = {
      allowed = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this host may enter a system sleep state. `false` masks
          sleep/suspend/hibernate/hybrid-sleep.target, which makes an
          accidental `systemctl suspend` or a stray sleep.target dependency a
          no-op instead of an outage.

          Set this `false` only for hardware that demonstrably cannot round-
          trip a suspend, or for a machine whose role makes sleep meaningless
          (an always-on hub). It is deliberately NOT a power-saving stance --
          hardware that suspends cleanly should keep suspending.
        '';
      };
      reason = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Required when sleep.allowed = false: why this host cannot or must not sleep. Asserted, so the mask can never appear without its justification.";
      };
    };

    cpu.energyPerformancePreference = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "default" "performance" "balance_performance" "balance_power" "power" ]);
      default = null;
      description = "cpufreq/energy_performance_preference for every CPU. `null` leaves the driver default alone (do not manage). Live-writable, so changing it does not need a reboot.";
    };

    pcie.aspmPolicy = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "default" "performance" "powersave" "powersupersave" ]);
      default = null;
      description = "PCIe ASPM policy, applied as a kernel parameter (pcie_aspm.policy). Boot-time only: a switch cannot apply it to the running kernel.";
    };

    sata = {
      alpmPolicy = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "max_performance" "medium_power" "med_power_with_dipm" "min_power" ]);
        default = null;
        description = "SATA link power management policy, by udev on any scsi_host exposing the attribute. Note min_power has a corruption history on some old consumer SSD firmware.";
      };
      mobileLpmPolicy = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = ''
          ahci.mobile_lpm_policy kernel parameter. Needed on non-mobile-flagged
          hardware: ahci otherwise locks link_power_management_policy to firmware
          defaults and REJECTS the sysfs write, even though the udev rule above
          fires correctly. Consulted at each host's initial probe, so it must be
          present from boot -- setting it live does not unlock an already-probed
          host. The verify service below catches exactly this class of silent
          rejection.
        '';
      };
    };

    runtimePm = {
      pci = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable PCI runtime PM (power/control=auto) for every PCI device except runtimePm.keepPowered.";
      };
      usb = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable USB autosuspend. Check the lsusb inventory first: safe when nothing on the bus is an input device, a UPS, or anything else autosuspend can disrupt.";
      };
      scsi = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable runtime PM on scsi_device leaf nodes (matched by the H:C:I:L numeric address form, which excludes scsi_host/scsi_target objects).";
      };
      keepPowered = lib.mkOption {
        default = [ ];
        description = ''
          PCI devices held at power/control=on, exempt from runtimePm.pci.
          Ordering is handled here: these rules are emitted after the general
          one in the same file, and a later ATTR write to the same attribute
          on the same device wins.

          NOTE the layer boundary -- this exempts a device from IDLE-time D3
          only. A system suspend still suspends it. If a device is listed here
          because it cannot survive being powered down, sleep.allowed almost
          certainly needs to be false too; nixpower warns when it is not.
        '';
        type = lib.types.listOf (lib.types.submodule {
          options = {
            vendor = lib.mkOption { type = lib.types.str; description = "PCI vendor ID as a udev ATTR string, e.g. \"0x1002\"."; };
            device = lib.mkOption { type = lib.types.str; description = "PCI device ID as a udev ATTR string, e.g. \"0x73bf\"."; };
            reason = lib.mkOption { type = lib.types.str; description = "Why this device stays powered. Required -- an unexplained exemption is indistinguishable from a forgotten one."; };
          };
        });
      };
    };

    writebackCentisecs = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "vm.dirty_writeback_centisecs (kernel default 500). Raising it stops periodic flush needlessly waking spun-down drives' non-ZFS filesystems. ZFS's own txg commit is a separate mechanism, unaffected.";
    };

    deviceCoredumps = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the kernel may write device coredumps (/sys/class/devcoredump/disabled).
        Kept ON by default: they are the primary post-mortem for a dead device.
        Worth turning off only on a host with a KNOWN repeating dump storm --
        the host wrote ~121k of them in one day while its GPU sat wedged,
        which was a meaningful share of that box's load.
      '';
    };

    ## ── Diagnostics. One option per tool, each named for what it answers ──────
    ## Deliberately NOT a single `tools.enable`: a host should not silently
    ## acquire a Seagate firmware utility. Storage-inspection CLIs
    ## (smartmontools, hdparm) belong to nixfs; BMC-shaped tools live in nixbmc.

    powertop.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "powertop: the periodic audit that finds knobs this module isn't managing yet. The tool that produced this host's original tuning list.";
    };

    cpupower.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "cpupower: read-only CPU-frequency and policy diagnostics. nixpower never enables its policy-writing service, so it cannot race this module's own CPU stance.";
    };

    lmSensors.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "lm_sensors: temperatures — the other half of any fan-vs-power tradeoff, and the first thing to check when a power setting makes something run hotter.";
    };

    openseachest.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        openSeaChest: Seagate EPC (Extended Power Conditions) idle_a/idle_b/standby_z
        timers. hdparm's -B only reaches the ATA APM level; when a Seagate parks on
        its own internal EPC timers, this is the only tool that can see or change
        them. Enable on hosts with Seagate drives whose Load_Cycle_Count keeps
        climbing after the APM level is already at 254.
      '';
    };

    verify.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run nixpower-verify after boot: read every managed knob back from sysfs
        and log PASS/FAIL per knob. This exists because a power knob can be
        requested correctly and silently refused by the kernel -- the SATA ALPM
        rule on the host fired correctly for days while every write was
        rejected, and nothing said so. Requesting a setting is not evidence that
        it took.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
    assertions = [
      {
        assertion = cfg.sleep.allowed || cfg.sleep.reason != "";
        message = "nixpower.sleep.allowed = false requires sleep.reason (why this host must not sleep).";
      }
    ];

    warnings = lib.optional (cfg.sleep.allowed && cfg.runtimePm.keepPowered != [ ]) ''
      nixpower: ${toString (builtins.length cfg.runtimePm.keepPowered)} PCI device(s) are held at power/control=on because they do not survive being powered down, but sleep.allowed is true on this host. A runtime-PM exemption does NOT survive a system suspend -- s2idle/S3 suspends every device regardless. This is the exact gap that wedged the host's RX 6800 on 2026-07-24. Either confirm the hardware round-trips a suspend, or set sleep.allowed = false.
    '';

    # Masked, not just disabled: a masked target cannot be pulled in by a
    # dependency either, which is the half that a disabled unit misses.
    systemd.targets = lib.mkIf (!cfg.sleep.allowed) (
      lib.genAttrs sleepTargets (_: { enable = false; })
    );

    boot.kernelParams =
      lib.optional (cfg.pcie.aspmPolicy != null) "pcie_aspm.policy=${cfg.pcie.aspmPolicy}"
      ++ lib.optional (cfg.sata.mobileLpmPolicy != null) "ahci.mobile_lpm_policy=${toString cfg.sata.mobileLpmPolicy}";

    boot.kernel.sysctl = lib.mkIf (cfg.writebackCentisecs != null) {
      "vm.dirty_writeback_centisecs" = cfg.writebackCentisecs;
    };

    services.udev.extraRules = lib.concatStringsSep "\n" (
      lib.optional (cfg.sata.alpmPolicy != null) ''
        # SATA link power management (ALPM/DIPM), matched by CLASS -- the
        # ATTR{...}=="?*" guard selects any scsi_host that EXPOSES the attribute,
        # rather than a hardcoded host number (not stable across reboots). The
        # attribute exists only on real ATA/libata hosts, not on USB mass-storage's
        # synthetic scsi_host entries, so this needs no USB exclusion.
        ACTION=="add", SUBSYSTEM=="scsi_host", ATTR{link_power_management_policy}=="?*", ATTR{link_power_management_policy}="${cfg.sata.alpmPolicy}"''
      ++ lib.optional cfg.runtimePm.scsi ''
        # scsi_device leaf nodes only: the H:C:I:L numeric address format is the
        # traditional, universally-supported way to exclude scsi_host/scsi_target.
        ACTION=="add|change", SUBSYSTEM=="scsi", KERNEL=="[0-9]*:[0-9]*:[0-9]*:[0-9]*", ATTR{power/control}="auto"''
      ++ lib.optional cfg.runtimePm.pci ''
        # General PCI runtime PM. keepPowered rules follow and override it.
        ACTION=="add", SUBSYSTEM=="pci", ATTR{power/control}="auto"''
      ++ lib.optional (cfg.runtimePm.keepPowered != [ ]) keepPoweredRules
      ++ lib.optional cfg.runtimePm.usb ''
        ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="auto"''
      ++ lib.optional (cfg.cpu.energyPerformancePreference != null) ''
        ACTION=="add", SUBSYSTEM=="cpu", ATTR{cpufreq/energy_performance_preference}="${cfg.cpu.energyPerformancePreference}"''
    );

    environment.systemPackages =
      lib.optional cfg.powertop.enable pkgs.powertop
      ++ lib.optional cfg.cpupower.enable config.boot.kernelPackages.cpupower
      ++ lib.optional cfg.lmSensors.enable pkgs.lm_sensors
      ++ lib.optional cfg.openseachest.enable pkgs.openseachest;

    systemd.services.nixpower-coredumps = lib.mkIf (!cfg.deviceCoredumps) {
      description = "nixpower: disable kernel device coredumps";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # The class node only exists once something registers devcoredump; tolerate its absence.
      script = ''
        if [ -w /sys/class/devcoredump/disabled ]; then
          echo 1 > /sys/class/devcoredump/disabled
        fi
      '';
    };

    # The udev rules above are the fast path and the ONLY path for a device hotplugged later;
    # this unit is the backstop for drivers that finish initialising after their bind uevent and
    # hand power/control back to runtime PM (see the keepPoweredRules note). It runs once, late,
    # when every driver has settled.
    #
    # It re-asserts rather than reconciles: no timer, no watch. A device that flips back to "auto"
    # after this point is a new fact about that driver, and nixpower-verify -- ordered after this
    # unit -- is what reports it. Papering over that with a polling loop would hide the one signal
    # worth having.
    systemd.services.nixpower-runtime-pm-assert = lib.mkIf (cfg.runtimePm.keepPowered != [ ]) {
      description = "nixpower: re-assert power/control=on for keepPowered devices once drivers have settled";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -uo pipefail   # no -e: an absent device is data, not an engine crash

        ${lib.concatMapStringsSep "\n" (d: ''
          # ${d.reason}
          for p in /sys/bus/pci/devices/*; do
            if [ "$(cat "$p/vendor" 2>/dev/null)" = "${d.vendor}" ] && [ "$(cat "$p/device" 2>/dev/null)" = "${d.device}" ]; then
              if [ ! -w "$p/power/control" ]; then
                echo "SKIP  ${d.vendor}:${d.device}: $p/power/control not writable"
                continue
              fi
              was="$(cat "$p/power/control" 2>/dev/null)"
              if [ "$was" = "on" ]; then
                echo "OK    ${d.vendor}:${d.device} already on ($p)"
              elif echo on > "$p/power/control"; then
                echo "SET   ${d.vendor}:${d.device} was '$was', now '$(cat "$p/power/control" 2>/dev/null)' ($p) -- a driver had handed it back to runtime PM"
              else
                echo "FAIL  ${d.vendor}:${d.device}: write to $p/power/control rejected"
              fi
            fi
          done
        '') cfg.runtimePm.keepPowered}
      '';
    };

    systemd.services.nixpower-verify = lib.mkIf cfg.verify.enable {
      description = "nixpower: read every managed power knob back and report what actually took";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ] ++ lib.optional (cfg.runtimePm.keepPowered != [ ]) "nixpower-runtime-pm-assert.service";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -uo pipefail   # no -e: a failed readback is data, not an engine crash
        fail=0

        check() { # $1 = label, $2 = expected, $3 = path (first match wins for globs)
          local label="$1" want="$2" path="$3" got
          # shellcheck disable=SC2086
          set -- $path
          if [ ! -r "$1" ]; then
            echo "SKIP  $label: $1 not readable on this host"
            return
          fi
          got="$(cat "$1" 2>/dev/null)"
          case "$got" in
            *"[$want]"*|"$want") echo "PASS  $label = $want" ;;
            *) echo "FAIL  $label: requested '$want', kernel reports '$got' ($1)"; fail=1 ;;
          esac
        }

        ${lib.optionalString (cfg.sata.alpmPolicy != null) ''
          check "sata.alpmPolicy" "${cfg.sata.alpmPolicy}" "/sys/class/scsi_host/host*/link_power_management_policy"
        ''}
        ${lib.optionalString (cfg.cpu.energyPerformancePreference != null) ''
          check "cpu.energyPerformancePreference" "${cfg.cpu.energyPerformancePreference}" "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"
        ''}
        ${lib.optionalString (cfg.pcie.aspmPolicy != null) ''
          check "pcie.aspmPolicy" "${cfg.pcie.aspmPolicy}" "/sys/module/pcie_aspm/parameters/policy"
        ''}
        ${lib.optionalString (cfg.writebackCentisecs != null) ''
          check "writebackCentisecs" "${toString cfg.writebackCentisecs}" "/proc/sys/vm/dirty_writeback_centisecs"
        ''}

        ${lib.optionalString (!cfg.sleep.allowed) ''
          for u in ${lib.concatMapStringsSep " " (t: "${t}.target") sleepTargets} ${lib.concatMapStringsSep " " (s: "${s}.service") sleepServices}; do
            if [ "$(${pkgs.systemd}/bin/systemctl is-enabled "$u" 2>/dev/null)" = "masked" ]; then
              echo "PASS  sleep.$u = masked"
            else
              echo "FAIL  sleep.$u is NOT masked -- this host can still be suspended"
              fail=1
            fi
          done
        ''}

        ${lib.concatMapStringsSep "\n" (d: ''
          for p in /sys/bus/pci/devices/*; do
            if [ "$(cat "$p/vendor" 2>/dev/null)" = "${d.vendor}" ] && [ "$(cat "$p/device" 2>/dev/null)" = "${d.device}" ]; then
              got="$(cat "$p/power/control" 2>/dev/null)"
              if [ "$got" = "on" ]; then
                echo "PASS  keepPowered ${d.vendor}:${d.device} = on"
              else
                echo "FAIL  keepPowered ${d.vendor}:${d.device} is '$got', wanted 'on' ($p)"
                fail=1
              fi
            fi
          done
        '') cfg.runtimePm.keepPowered}

        if [ "$fail" -ne 0 ]; then
          # NOT "the kernel declined it" -- that phrasing sent an investigation down the wrong
          # path for three days. sysfs almost never rejects these writes; it accepts them and
          # something overwrites the value afterwards. The common causes, in order of likelihood:
          # a driver re-enabling runtime PM from its own probe (what nixpower-runtime-pm-assert
          # exists to undo), another config on the host writing the same knob, or the attribute
          # not existing in the shape this host's kernel exposes.
          echo "nixpower-verify: at least one knob did not take -- see the FAIL lines above. A write sysfs ACCEPTED can still be overwritten later; check what else on this host touches that attribute before concluding the hardware refused it."
          exit 1
        fi
        echo "nixpower-verify: every managed knob verified against sysfs."
      '';
    };
    }

    # SEPARATE MERGE BRANCH, and it has to be one. This is the only
    # `systemd.services` definition in the file with DYNAMIC keys, so it must be a
    # whole-attrset assignment -- while the branch above declares static
    # `systemd.services.nixpower-{coredumps,verify}` entries by path. A single Nix
    # attrset literal cannot hold both `a = ...;` and `a.b = ...;`: it fails with
    # "attribute 'systemd.services' already defined" at PARSE time, before the module
    # system's own merge logic is ever reached, so no amount of mkIf/mkMerge on the
    # value side fixes it. Splitting the config into merge branches does.
    #
    # Same treatment as systemd.targets above for the units those targets pull in, so
    # the direct-by-name route into sleep is closed too.
    {
      systemd.services = lib.mkIf (!cfg.sleep.allowed) (
        lib.genAttrs sleepServices (_: { enable = false; })
      );
    }
  ]);
}
