{ pkgs, lib, systemManagerModule }:

let
  evaluate = extraConfig:
    (lib.evalModules {
      modules = [
        systemManagerModule
        {
          options = {
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
            };
            systemd.tmpfiles.rules = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            systemd.services = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            environment.etc = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
        }
        extraConfig
      ];
    }).config;

  configured = evaluate {
    nixpower = {
      tlp.enable = true;
      tlpRdw.enable = true;
      powertop.enable = true;
      cpupower.enable = true;
      brightnessctl.enable = true;
    };
  };

  # brightnessctl is the one entry here that is neither a power daemon nor its diagnostic, so it
  # gets its own fixture: nothing else in this module must arrive with it, and it must not arrive
  # with anything else. A single all-on fixture proves the union and would happily pass if the
  # entry were accidentally attached to `powertop.enable`.
  brightnessOnly = evaluate {
    nixpower.brightnessctl.enable = true;
  };

  invalidRdw = evaluate {
    nixpower.tlpRdw.enable = true;
  };

  checks = [
    {
      name = "system-manager/native-package-output";
      ok = configured.nixpower.archPackages == [ "tlp" "tlp-rdw" "powertop" "cpupower" "brightnessctl" ];
      detail = "expected the selected native package list to contain TLP, TLP-RDW, powertop, cpupower, and brightnessctl in deterministic order";
    }
    {
      name = "system-manager/brightnessctl-is-independent";
      ok = brightnessOnly.nixpower.archPackages == [ "brightnessctl" ];
      detail = "expected a host that asks only for the backlight control to get exactly that, with no TLP, powertop or cpupower riding along";
    }
    {
      name = "system-manager/cpupower-service-stays-disabled";
      ok = lib.elem "r /etc/systemd/system/multi-user.target.wants/cpupower.service - - - -" configured.systemd.tmpfiles.rules;
      detail = "expected cpupower to remove its multi-user enablement symlink while leaving the diagnostic CLI installed";
    }
    {
      name = "system-manager/tlp-rdw-requires-tlp";
      ok = lib.any (a: !a.assertion) invalidRdw.assertions;
      detail = "expected enabling TLP-RDW without TLP to produce a failed module assertion";
    }
  ];

  failed = builtins.filter (check: !check.ok) checks;
  report = lib.concatMapStringsSep "\n" (check: "  - ${check.name}: ${check.detail}") failed;
in
if failed != [ ]
then throw "nixpower system-manager checks FAILED:\n${report}"
else pkgs.runCommand "nixpower-system-manager-checks" { } ''
  touch $out
''
