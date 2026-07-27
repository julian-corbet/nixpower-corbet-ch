# Experiments

Throwaway trials. Nothing here is maintained or imported by the modules.

| File | What |
|---|---|
| `eval-smoke-test.nix` | Evaluates the system-manager backend and asserts every unit in `lib/sleep-units.nix` actually gets a masking rule — the drift that left `suspend-then-hibernate.target` and the four `systemd-*.service` units unmasked when each backend kept its own inline copy. |
