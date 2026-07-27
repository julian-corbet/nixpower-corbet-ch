# Throwaway eval smoke test -- NOT part of the module surface. Confirms the system-manager backend
# evaluates and that `sleep.allowed = false` actually produces the full masked set, before any of it
# is published. Safe to delete; nothing imports this file.
#
# Uses lib.evalModules rather than nixosSystem on purpose: the sleep half is options plus tmpfiles
# rules and one etc file, so a bare module evaluation is sufficient and far cheaper than
# instantiating a whole system. (The NixOS backend cannot be smoke-tested this way -- it reaches
# into systemd.targets/systemd.services/services.udev, which only exist inside a real NixOS eval.)
#
#   nix-instantiate --eval --strict experiments/eval-smoke-test.nix -A maskedCount   # => 9
#   nix-instantiate --eval --strict experiments/eval-smoke-test.nix -A missing       # => [ ]
{ nixpkgs ? <nixpkgs> }:
let
  lib = (import nixpkgs { }).lib;
  units = import ../lib/sleep-units.nix { };

  eval = lib.evalModules {
    modules = [
      ../modules/system-manager.nix
      # Minimal stubs for the two option trees the module writes into. system-manager declares
      # these itself; here they only need to exist so the module's config can land somewhere.
      {
        options.systemd.tmpfiles.rules = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
        options.environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
        options.systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
      }
      {
        services.nixpower.sleep = {
          allowed = false;
          reason = "smoke test";
          maskSysfs = true;
        };
      }
    ];
  };

  rules = eval.config.systemd.tmpfiles.rules;

  # Every unit the shared list says must be masked, in the form the rules use.
  expected = (map (t: "${t}.target") units.targets) ++ (map (s: "${s}.service") units.services);
in
{
  # The whole point of lib/sleep-units.nix: a backend must mask ALL of them. 9 at time of writing.
  maskedCount = builtins.length rules;

  # Empty list = every expected unit has a masking rule. A non-empty list is the drift this file
  # exists to catch -- exactly the failure that left suspend-then-hibernate.target and all four
  # systemd-*.service units unmasked while each backend kept its own inline copy.
  missing = builtins.filter (u: !(builtins.any (r: lib.hasInfix u r) rules)) expected;

  # maskSysfs is the one option with no NixOS equivalent; confirm it actually emits its unit.
  hasSysfsMask = eval.config.systemd.services ? nixpower-mask-sys-power;

  # The assertion that stops a mask appearing without its justification.
  reasonAsserted = builtins.length eval.config.assertions > 0;
}
