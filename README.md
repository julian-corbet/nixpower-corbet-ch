# nixpower

One declarative power stance per host — sleep policy, runtime PM, and a verifier that reads every
knob back from sysfs instead of trusting that it was applied.

## Why

The incident this was written after was not caused by a missing knob. Every individual setting on
the host was deliberate and correct, *including* an explicit exemption holding a desktop-class AMD
GPU at `power/control=on`, because D3 resume on that hardware is known-glitchy.

The machine still lost its GPU for a day.

A **system** suspend suspends every device regardless of its runtime-PM policy. The per-device
exemption and the system sleep state are two different layers, and nothing in the config could
express the sentence *"this host cannot survive a suspend."* That sentence is `sleep.allowed`, and
the mismatch between the two layers is now an explicit eval-time warning.

## The two backends

| Module | For | Owns |
|---|---|---|
| `nixosModules.nixpower` | NixOS | sleep policy, PCI/USB/SCSI runtime PM, CPU EPP, PCIe ASPM, SATA ALPM, dirty-writeback, coredumps, `nixpower-verify` |
| `systemManagerModules.nixpower` | Arch / non-NixOS via [system-manager][sm] | sleep policy, plus native TLP/diagnostic package intent |

Same option names on both, so a host reads identically whichever manager drives it. Only the
mechanism differs: NixOS masks with `systemd.units.<name>.enable = false`, system-manager with a
tmpfiles `L+` symlink to `/dev/null` — which is what `systemctl mask` does anyway.

The system-manager backend deliberately does not configure CPU, ASPM, runtime-PM, or storage knobs.
A non-NixOS host usually has a distro power daemon (TLP and friends) already managing them, and
pointing two mechanisms at one knob is the exact failure this project exists to prevent. It can
publish `nixpower.archPackages` for that daemon, its diagnostics and the backlight control
(`brightnessctl` — display power, driven by a person rather than held as a policy, so it cannot race
the daemon); the host's package reconciler installs those native packages.

## `nixpower.diskStandby` — ATA standby spin-down, its own module

`nixosModules.diskStandby` (`modules/disk-standby.nix`) spins down idle rotational drives via the
ATA standby timer (`hdparm -S`), entirely in hardware — no daemon, no polling, resets on any
access. A blanket udev rule matches every internal (non-USB) block device reporting
`queue/rotational=1`; SSD/NVMe are excluded by the query itself. `apmLevel` (`hdparm -B`) is a
separate, optional knob for drives whose Advanced Power Management is unloading heads far more
often than the standby timer alone would suggest. `staggerGroups` renders a oneshot that wakes a
named set of devices in sequence rather than all at once, for wiring into another unit's
`wants`/`after` (a predictable nightly job, say) — it is not inrush protection, which this module
deliberately does not attempt (see the module's own header for why).

Kept **separate** from `nixosModules.nixpower` on purpose, not merged in: ATA standby timers are
storage policy that happens to save power, keyed off `queue/rotational` and the USB exclusion —
not the system-wide sleep/runtime-PM stance the main module owns. A host that wants both imports
both; `nixpower`'s own module header says so explicitly, so the boundary can't be re-blurred by
someone reaching for "just add it here" later.

```nix
nixpower.diskStandby = {
  enable = true;
  timeoutMinutes = 30;
  apmLevel = 254; # only if Load_Cycle_Count is climbing — see the option's own description
};
```

NixOS only — no system-manager backend exists for this module.

## Usage

```nix
nixpower = {
  enable = true;
  sleep.allowed = false;
  sleep.reason = "always-on hub; its GPU has never survived an s2idle resume";

  runtimePm.pci = true;
  runtimePm.keepPowered = [
    { vendor = "0x1002"; device = "0x73a6"; reason = "USB-C controller dies on D3 resume"; }
  ];
};
```

`sleep.reason` is **asserted** when `sleep.allowed = false`: the mask can never appear in a config
without its justification sitting next to it.

## Two things learned the hard way

**Masking targets is not enough.** `systemctl start systemd-suspend.service` addresses the unit
directly and never touches a target, so a host with every `*.target` masked and the `systemd-*.service`
units left `static` is still suspendable. Both lists live in `lib/sleep-units.nix`, shared by the two
backends — they drifted while each kept its own copy, which is how `suspend-then-hibernate.target`
stayed unmasked on every consumer for a while.

**An `ACTION=="add"` udev rule loses a race it looks like it wins.** A driver's `probe()` may
re-enable runtime PM for its own device — `xhci_hcd` calls `pm_runtime_allow()`, writing
`power/control` back to `auto` — and that happens *after* the add event udev reacted to. The
`keepPowered` rules therefore match `ACTION=="add|bind"`: `bind` fires once the driver has had its
say, which is where the pin actually sticks.

## Verifying

`nixpower-verify` runs after boot and reads every managed knob back from sysfs, logging `PASS`/`FAIL`
per knob. It was written because a SATA ALPM rule fired correctly for days while the kernel rejected
every write, and nothing surfaced it.

## License

MIT.

[sm]: https://github.com/numtide/system-manager
