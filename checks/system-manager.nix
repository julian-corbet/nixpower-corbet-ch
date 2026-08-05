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
    };
  };

  invalidRdw = evaluate {
    nixpower.tlpRdw.enable = true;
  };

  checks = [
    {
      name = "system-manager/native-package-output";
      ok = configured.nixpower.archPackages == [ "tlp" "tlp-rdw" "powertop" "cpupower" ];
      detail = "expected the selected native package list to contain TLP, TLP-RDW, powertop, and cpupower in deterministic order";
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
