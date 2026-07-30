{
  description = "nixpower — one declarative power stance per host: sleep policy, runtime PM, and a verifier that reads every knob back";

  # nixpkgs is a CHECKS-ONLY dependency: `checks/` composes a throwaway NixOS system to prove the
  # modules' generated units/assertions behave, both here at the flake level. Every shipped module
  # still takes `pkgs` from the CONSUMER's own module evaluation, never from this input directly —
  # a consumer importing nixosModules.nixpower/.diskStandby never ends up with two nixpkgs in its
  # closure because of this flake.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
    # ── NixOS ─────────────────────────────────────────────────────────────────────────────────
    # The full stance: sleep policy, PCI/USB/SCSI runtime PM, CPU EPP, PCIe ASPM, SATA ALPM,
    # dirty-writeback, device coredumps, plus `nixpower-verify` which reads every managed knob
    # back from sysfs after boot and logs PASS/FAIL. That verifier exists because a udev rule can
    # fire correctly for days while the kernel rejects every write, and nothing says so.
    nixosModules.nixpower = ./modules/nixos.nix;
    nixosModules.default = ./modules/nixos.nix;

    # nixpower.diskStandby -- ATA standby-timer spin-down for rotational drives, a udev rule plus
    # an optional APM-level write and staggered-wake helper. SEPARATE from nixosModules.nixpower
    # on purpose (see modules/disk-standby.nix's own header): storage policy that happens to save
    # power is not the same knob as the system-wide sleep/runtime-PM stance, and pointing two
    # mechanisms at one knob is the exact failure this project exists to prevent. A host that
    # wants both imports both.
    nixosModules.diskStandby = ./modules/disk-standby.nix;

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

    # Proves the generated units/assertions behave, not merely that the options exist. See
    # checks/default.nix for what each one establishes.
    checks = forAllSystems (system:
      import ./checks {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit lib nixpkgs system;
        nixpowerModule = self.nixosModules.nixpower;
        diskStandbyModule = self.nixosModules.diskStandby;
      });

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
  };
}
