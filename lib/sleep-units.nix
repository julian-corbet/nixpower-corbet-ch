#
# The sleep entry points, in ONE place.
#
# WHY THIS FILE EXISTS. nixpower ships two backends — a NixOS module and a system-manager module —
# because the two module systems mask a unit differently (`systemd.units.<name>.enable = false`
# versus a tmpfiles `L+` symlink to /dev/null). They must nonetheless mask the SAME set, and while
# these lists lived inline in each backend they drifted: `suspend-then-hibernate.target` was in
# neither, and the `systemd-*.service` units were in neither, so for a while every host using the
# module had two unmasked routes to a suspend. Both gaps were found live, not by reading the code.
#
# So the lists live here and the backends import them. A backend can differ in HOW it masks; it
# cannot differ in WHAT.
#
{ ... }:
{
  # The .targets. These are what a dependency pulls in — `systemctl suspend`, a lid event, an idle
  # action all route through one of these.
  targets = [
    "sleep"
    "suspend"
    "hibernate"
    "hybrid-sleep"
    "suspend-then-hibernate"
  ];

  # The .service units, which matter SEPARATELY. Masking sleep.target blocks the dependency route,
  # but `systemctl start systemd-suspend.service` addresses the unit directly and never touches a
  # target. A host with every target masked and these left `static` is still suspendable.
  services = [
    "systemd-suspend"
    "systemd-hibernate"
    "systemd-hybrid-sleep"
    "systemd-suspend-then-hibernate"
  ];
}
