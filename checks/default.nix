# checks/default.nix
#
# Two kinds of test:
#
#   modules-evaluate: composes nixpower + nixpower.diskStandby against
#   examples/host/configuration.nix through NixOS's own eval-config.nix and
#   forces system.build.toplevel.drvPath (string context discarded, so this
#   EVALUATES a system rather than building one) -- catches a type error, a
#   failed assertion, or an option rename across both modules at once.
#
#   Behavioural checks over the GENERATED artifacts (the udev rules string,
#   the stagger-group systemd services) -- each proven in both directions
#   where the module has a real fires/doesn't-fire boundary (a type
#   constraint, a conditional RUN+= line), not just "it evaluates".
{ pkgs, lib, nixpkgs, system, nixpowerModule, diskStandbyModule, systemManagerModule }:

let
  host = lib.nixosSystem {
    inherit system;
    modules = [
      nixpowerModule
      diskStandbyModule
      ../examples/host/configuration.nix
    ];
  };

  modules-evaluate =
    pkgs.writeText "nixpower-host-drvpath"
      (builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath);

  # `nixpower.diskStandby.apmLevel` is typed `nullOr (ints.between 1 255)` --
  # forcing `system.build.toplevel` is what makes NixOS actually enforce a
  # type constraint, exactly the same reasoning nixbackup/nixstorage's own
  # `buildFails` helpers document.
  evalDiskStandby = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        diskStandbyModule
        extraConfig
        {
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          boot.loader.grub.enable = false;
          system.stateVersion = "25.05";
        }
      ];
    }).config;

  # `.drvPath`, not a bare `seq` of the toplevel attrset: a TYPE constraint
  # (like `apmLevel`'s `nullOr (ints.between 1 255)`) is only enforced when
  # the value is actually forced deep enough to build the derivation that
  # embeds it (here, the generated udev-rules text) -- WHNF-ing the bare
  # `system.build.toplevel` attrset (sufficient for a `config.assertions`
  # failure, which is thrown directly by eval-config.nix's own toplevel
  # construction) does not reach that far on its own.
  buildFails = extraConfig:
    !(builtins.tryEval (
      builtins.seq (builtins.unsafeDiscardStringContext (evalDiskStandby extraConfig).system.build.toplevel.drvPath) true
    )).success;

  check = name: ok: detail: { inherit name ok detail; };

  udevRules = host.config.services.udev.extraRules;
  staggerService = host.config.systemd.services.nixpower-diskstandby-wake-example-pool or null;

  results = [
    # --- the standby-timer RUN+= line is present, scoped to rotational, non-USB block devices ---
    (check "disk-standby/udev-rule-scopes-rotational-non-usb"
      (lib.hasInfix ''ATTR{queue/rotational}=="1"'' udevRules
        && lib.hasInfix ''ENV{ID_BUS}!="usb"'' udevRules)
      "expected the generated udev rule to gate on queue/rotational==1 and exclude USB, but one or both were missing")

    (check "nixos/cpupower-is-an-explicit-read-only-diagnostic"
      (lib.elem host.config.boot.kernelPackages.cpupower host.config.environment.systemPackages)
      "expected nixpower.cpupower.enable to add cpupower to the NixOS system package set")

    # --- timeoutMinutes=30 (1800s, over the 1200s/240-step boundary) encodes to the 30-min-step
    # form: 240 + (30/30) = 241 -- proves the encoding helper actually ran, not just "some -S flag
    # is present".
    (check "disk-standby/timeout-encodes-to-expected-hdparm-value"
      (lib.hasInfix "-S 241" udevRules)
      "expected timeoutMinutes=30 to encode as hdparm -S 241 (240 + 30/30, the 30-minute-step form), but it did not appear")

    # --- apmLevel, when set, is a SEPARATE RUN+= (not appended to the -S line) -- hdparm aborts
    # the rest of its flags on the first failure, so a drive that rejects -B must not also lose -S.
    (check "disk-standby/apm-level-is-a-separate-run-line"
      (
        let
          runLines = lib.filter (l: lib.hasInfix "RUN+=" l) (lib.splitString "\n" udevRules);
        in
        lib.length runLines == 2
        && lib.any (l: lib.hasInfix "-S 241" l) runLines
        && lib.any (l: lib.hasInfix "-B 254" l) runLines
      )
      "expected exactly two RUN+= lines (one hdparm -S, one hdparm -B 254) when apmLevel is set, so a drive rejecting -B never loses its -S standby timer")

    # --- apmLevel omitted (null, the default) emits no -B line at all --------------------------
    (check "disk-standby/apm-level-omitted-emits-no-b-flag"
      (
        let
          rules = (evalDiskStandby {
            nixpower.diskStandby = {
              enable = true;
              timeoutMinutes = 30;
            };
          }).services.udev.extraRules;
        in
        !(lib.hasInfix "-B " rules)
      )
      "expected no hdparm -B line when apmLevel is left at its null default, but one was emitted")

    # --- apmLevel is a bounded ATA byte (1-255) -- out of range must fail the build, not silently
    # clamp or wrap.
    (check "disk-standby/apm-level-out-of-range-fails-the-build"
      (buildFails {
        nixpower.diskStandby = {
          enable = true;
          apmLevel = 0;
        };
      })
      "expected nixpower.diskStandby.apmLevel = 0 (outside the valid 1-255 ATA range) to fail the build, but it succeeded")

    (check "disk-standby/apm-level-in-range-builds-fine"
      (
        !(buildFails {
          nixpower.diskStandby = {
            enable = true;
            apmLevel = 254;
          };
        })
      )
      "nixpower.diskStandby.apmLevel = 254 (a valid ATA byte) should never fail the build on its own")

    # --- timeoutMinutes must be a positive int -- zero/negative has no sane hdparm -S encoding ---
    (check "disk-standby/zero-timeout-fails-the-build"
      (buildFails {
        nixpower.diskStandby = {
          enable = true;
          timeoutMinutes = 0;
        };
      })
      "expected nixpower.diskStandby.timeoutMinutes = 0 to fail the build (ints.positive), but it succeeded")

    # --- staggerGroups renders one oneshot per group, reading each device in wake order ----------
    (check "disk-standby/stagger-group-renders-a-oneshot-per-device-in-order"
      (
        staggerService != null
        && lib.hasInfix "example-drive-0" staggerService.script
        && lib.hasInfix "example-drive-1" staggerService.script
        && (
          let
            script = staggerService.script;
            posA = lib.strings.stringLength (builtins.head (lib.splitString "example-drive-0" script));
            posB = lib.strings.stringLength (builtins.head (lib.splitString "example-drive-1" script));
          in
          posA < posB
        )
      )
      "expected nixpower-diskstandby-wake-example-pool's script to read example-drive-0 before example-drive-1 (declaration order), but the service was missing or misordered")
  ];

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-tests =
    if failed != [ ]
    then
      throw ''
        nixpower eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
      pkgs.runCommand "nixpower-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixpower eval tests passed"
          touch $out
        '';
in
{
  inherit modules-evaluate eval-tests;
  system-manager-package-contract = import ./system-manager.nix {
    inherit pkgs lib systemManagerModule;
  };
}
