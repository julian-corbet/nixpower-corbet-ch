# modules/disk-standby.nix
#
# Spin down idle rotational drives via the ATA standby timer, IN HARDWARE --
# no daemon, no polling, resets automatically on any access. A blanket udev
# rule (any INTERNAL block device reporting queue/rotational=1) rather than
# an enumerated device list: catches every spinning drive on the host
# uniformly, and self-extends to any spinning drive added later with zero
# rewiring. SSDs report rotational=0 and are never touched -- excluded by
# the query itself, not by a maintained exclusion list.
#
# SEPARATE FROM `nixpower`'s own module, deliberately (see that module's own
# SCOPE note): ATA standby timers are storage policy that happens to save
# power, keyed off queue/rotational and the USB exclusion below, not a
# system-wide sleep/runtime-PM stance. Two mechanisms owning one knob is the
# exact failure this whole project exists to prevent -- so this stays its
# own file, its own option root, imported on its own.
#
# ENV{ID_BUS}!="usb" is required, not decorative: two USB thumb drives
# tested on a real host both misreport rotational=1 in sysfs, and `hdparm -S`
# is an ATA command consumer USB-storage bridges don't pass through -- it
# failed loudly (exit 22) rather than silently, but sending it at all is
# wrong: it has no business touching removable USB media regardless of
# whether the bridge happens to accept it.
#
# -B (APM level) is DELIBERATELY separate from -S (the standby timer) and
# left untouched unless `apmLevel` is explicitly set. Some drive firmwares
# implement their OWN fine-grained load-cycling once APM is enabled at an
# aggressive level, independent of -S -- on some firmwares this means far
# MORE head-park cycles than intended (Load_Cycle_Count wear), not fewer.
# -S alone (the ATA STANDBY TIMER) is coarse and predictable: park + spin
# down once after idle, stay down until the next real access -- and it
# operates independently of whatever -B is already set to. See `apmLevel`'s
# own description for when a drive's APM level itself needs raising instead
# (a distinct, rarer problem: aggressive head-parking WHILE still spinning).
#
# staggerGroups is a SEPARATE, opt-in concern: a named group of devices that
# some OTHER unit is about to wake in lockstep on a predictable schedule
# (e.g. every member of one RAID vdev right before a nightly backup).
# Generates a oneshot that reads each device in sequence with a delay, so
# the group wakes staggered instead of simultaneously -- wire it in via that
# other unit's `wants`/`after`.
#
# NOT cold-boot inrush protection -- deliberately out of scope. Simultaneous
# spin-up of many drives at once draws a real current spike, but at the
# scale of a typical home/small-office server (a handful to a dozen spinning
# drives) that spike is well inside what an adequately sized PSU tolerates;
# 45Drives (who build 45-bay storage servers) measured ~50A peak on the 12V
# rail spinning up 45 drives simultaneously vs ~15A staggered, and their own
# conclusion is that staggering "is not necessarily needed" at that scale
# given an adequate PSU. `staggerGroups` above exists for the orthogonal
# concern (avoid a PREDICTABLE unit slamming several drives awake at once,
# on top of whatever cold-boot behavior the BIOS/HBA itself already
# provides) -- it is not a substitute for real inrush protection, and no
# host in this family has needed one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixpower.diskStandby;

  # ATA standby-timer encoding (hdparm -S / IDENTIFY DEVICE table):
  #   1-240   => value*5 seconds   (5 sec .. 20 min)
  #   241-251 => (value-240)*30 min (30 min .. 5.5 hours)
  # Rounds DOWN to the nearest representable step so the real timeout never
  # exceeds what was asked for.
  mkStandbyValue =
    minutes:
    let
      seconds = minutes * 60;
    in
    if minutes <= 0 then
      0
    else if seconds <= 1200 then
      lib.max 1 (seconds / 5)
    else
      lib.min 251 (240 + (minutes / 30));

  staggerService =
    name: group:
    lib.nameValuePair "nixpower-diskstandby-wake-${name}" {
      description = "Sequentially wake the '${name}' disk group (staggered, not simultaneous)";
      serviceConfig.Type = "oneshot";
      script = lib.concatStringsSep "\nsleep ${toString group.gapSeconds}\n" (
        map (d: "${pkgs.coreutils}/bin/dd if=${d} of=/dev/null bs=4096 count=1 status=none") group.devices
      );
    };
in
{
  options.nixpower.diskStandby = {
    enable = lib.mkEnableOption "ATA standby spin-down for rotational drives";

    timeoutMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = ''
        Idle time before a rotational drive parks and spins down. Applied
        via udev at device add/change to EVERY block device reporting
        queue/rotational=1 -- SSD/NVMe unaffected. See the ATA standby-timer
        encoding comment above for the achievable granularity.
      '';
    };

    apmLevel = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 1 255);
      default = null;
      description = ''
        ATA Advanced Power Management level (`hdparm -B`), applied to the same
        drives as the standby timer. `null` leaves the drive's factory value alone.

        This is NOT the spin-down knob -- that is timeoutMinutes. APM governs how
        eagerly the drive parks its HEADS while still spinning, and the two are
        independent: 128-254 all disable APM-driven spindown, but only 254/255 stop
        the aggressive head unloading. 254 = "minimum power without any APM-driven
        head parking"; 255 disables APM entirely (some drives reject it).

        Set this when a drive's own Load_Cycle_Count SMART attribute is climbing
        fast relative to its power-on hours -- some drive-managed-SMR and
        laptop-class drives ship with APM at a default level (commonly 128) that
        unloads heads many times per hour even while otherwise idle, well before
        the standby timer above ever gets a chance to park them for good. The
        power cost of 254 is a fraction of a watt (heads stay loaded during idle);
        the standby timer above still spins the platters down at `timeoutMinutes`,
        which is where the actual watts are. Drives that don't support APM fail
        this harmlessly ("not supported") and keep their standby timer.
      '';
    };

    staggerGroups = lib.mkOption {
      default = { };
      description = ''
        Named groups of devices that predictably wake together on some
        OTHER unit's schedule. Generates one oneshot service
        `nixpower-diskstandby-wake-<name>.service` that reads each device in
        sequence with `gapSeconds` between reads -- wire it into that other
        unit's `wants`/`after`.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            devices = lib.mkOption {
              type = lib.types.listOf lib.types.path;
              description = "/dev/disk/by-id/... paths, in wake order.";
            };
            gapSeconds = lib.mkOption {
              type = lib.types.ints.positive;
              default = 4;
              description = "Delay between waking successive devices in this group.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ENV{ID_BUS}!="usb", RUN+="${pkgs.hdparm}/bin/hdparm -S ${toString (mkStandbyValue cfg.timeoutMinutes)} /dev/%k"${lib.optionalString (cfg.apmLevel != null) ''

      # Separate RUN, not a second flag on the line above: hdparm applies flags
      # left-to-right and aborts the rest on the first failure, so a drive that
      # doesn't support -B would also lose its -S standby timer.
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ENV{ID_BUS}!="usb", RUN+="${pkgs.hdparm}/bin/hdparm -B ${toString cfg.apmLevel} /dev/%k"''}
    '';

    systemd.services = lib.mapAttrs' staggerService cfg.staggerGroups;
  };
}
