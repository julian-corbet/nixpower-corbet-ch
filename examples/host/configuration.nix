# The smallest NixOS configuration that composes nixpower's NixOS modules
# together, used by every check in this flake.
#
# This is not a machine anyone would run: the root filesystem is tmpfs and
# every PCI/device ID below is a placeholder. It exists so the modules can
# be type-checked and so the units/rules they generate can be asserted
# against — nothing here touches real hardware.
{ ... }:
{
  # ── nixpower: the general power stance ──────────────────────────────────
  nixpower = {
    enable = true;

    # A device held at power/control=on despite general PCI runtime PM being
    # on — exercises `keepPowered`, the warning it can trigger when
    # `sleep.allowed` is left true, and `nixpower-verify`'s per-device check.
    runtimePm.pci = true;
    runtimePm.keepPowered = [
      {
        vendor = "0x1002";
        device = "0x73a6";
        reason = "example: this function is known not to survive a D3 resume";
      }
    ];

    cpu.energyPerformancePreference = "balance_power";
    cpupower.enable = true;
    pcie.aspmPolicy = "powersave";
    sata.alpmPolicy = "med_power_with_dipm";
    writebackCentisecs = 1500;
  };

  # ── nixpower.diskStandby: ATA standby-timer spin-down ────────────────────
  nixpower.diskStandby = {
    enable = true;
    timeoutMinutes = 30;
    apmLevel = 254;

    staggerGroups.example-pool = {
      devices = [
        "/dev/disk/by-id/example-drive-0"
        "/dev/disk/by-id/example-drive-1"
      ];
      gapSeconds = 4;
    };
  };

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-node";
  system.stateVersion = "25.05";
}
