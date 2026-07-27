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
| `systemManagerModules.nixpower` | Arch / non-NixOS via [system-manager][sm] | the sleep half only, same option surface, plus `sleep.maskSysfs` |

Same option names on both, so a host reads identically whichever manager drives it. Only the
mechanism differs: NixOS masks with `systemd.units.<name>.enable = false`, system-manager with a
tmpfiles `L+` symlink to `/dev/null` — which is what `systemctl mask` does anyway.

The system-manager backend is deliberately *not* the whole module. A non-NixOS host usually has a
distro power daemon (TLP and friends) already managing EPP, ASPM and spindown, and pointing two
mechanisms at one knob is the exact failure this project exists to prevent.

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
