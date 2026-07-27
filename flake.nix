{
  description = "nixpower — one declarative power stance per host: sleep policy, runtime PM, and a verifier that reads every knob back";

  # NO INPUTS. This flake is options and generated udev/systemd text — pure Nix, no package set.
  # Both modules take `pkgs` from the consumer's own module evaluation rather than a pinned
  # nixpkgs, so a consumer never ends up with two nixpkgs in its closure because of this flake.

  outputs = { self }: {
    # ── NixOS ─────────────────────────────────────────────────────────────────────────────────
    # The full stance: sleep policy, PCI/USB/SCSI runtime PM, CPU EPP, PCIe ASPM, SATA ALPM,
    # dirty-writeback, device coredumps, plus `nixpower-verify` which reads every managed knob
    # back from sysfs after boot and logs PASS/FAIL. That verifier exists because a udev rule can
    # fire correctly for days while the kernel rejects every write, and nothing says so.
    nixosModules.nixpower = ./modules/nixos.nix;
    nixosModules.default = ./modules/nixos.nix;

    # ── system-manager (Arch and other non-NixOS hosts) ───────────────────────────────────────
    # The SLEEP half only, with a deliberately identical option surface
    # (`nixpower.sleep.{allowed,reason}`) so a host reads the same on either manager.
    #
    # Only the sleep half, because the rest of the NixOS module emits udev rules and kernel
    # parameters that a system-manager host either cannot set or should not: such a host usually
    # has a distro power daemon (TLP and friends) already managing EPP/ASPM/spindown, and pointing
    # two mechanisms at one knob is the failure this module exists to prevent.
    #
    # It also carries `sleep.maskSysfs`, which has no NixOS equivalent: mounting a read-only tmpfs
    # over /sys/power. That is only meaningful where /sys is the HOST's sysfs rather than the
    # machine's own — a privileged container — where a raw `echo mem > /sys/power/state` never
    # goes near systemd and unit masking therefore cannot stop it.
    systemManagerModules.nixpower = ./modules/system-manager.nix;
    systemManagerModules.default = ./modules/system-manager.nix;

    # The masked unit set, exposed so a consumer can assert against it without re-listing it.
    lib.sleepUnits = import ./lib/sleep-units.nix { };
  };
}
