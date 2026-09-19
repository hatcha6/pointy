"""Is every installation in the fleet past a given version?

The standing question behind any **contract** migration — one that removes
something the previous release still writes. ``zero-downtime-updates`` is the
constraint: the edge nginx runs the previous release against the new schema
for about a minute, so a column that release still names is a 500 for that
minute, and ``relay-remote-update`` lets shops sit pinned, paused or on a
canary — there is always a real possibility that one shop is three releases
behind.

This asks the relay and answers. Read-only, it changes nothing, and its exit
code is the gate:

    python manage.py check_fleet_minimum_version --floor 2.12.0

Exit 0 means every installation that has reported a version is at or past the
floor and none is silent — the only state in which such a drop is safe.
Anything else exits non-zero and names what is holding it shut.

Why this exists as a command rather than as a note in a runbook: the
serialized-inventory plan shipped its expand and its contract in the *same*
release once, which for a shop already using the affected feature would have
been a ``ProgrammingError`` on every sale during the flip minute and no clean
rollback. It was caught before it reached a shop. The batch split's own
contract step then turned out not to need this at all — no shop had ever used
expiry tracking, so no previous release could touch the columns on the path
that mattered (``inventory/migrations/0037``) — but the *next* contract
release will need it, and ``Product.tracks_expiry`` is already queued to be
one: dropping that column makes the previous release fail on every product
read, which no usage argument mitigates.
"""

from __future__ import annotations

from django.core.management.base import BaseCommand

#: A version segment that is not a number sorts before every number, so an
#: unparseable version behaves like an old one. That is the safe direction for
#: a gate whose whole job is to refuse when it is unsure. Mirrors
#: ``relay/internal/control/fleet_version.go`` deliberately: the two answers
#: must agree, and each is short enough to read side by side.
def compare_versions(left: str, right: str) -> int:
    left_parts = (left or "").strip().split(".")
    right_parts = (right or "").strip().split(".")
    for index in range(max(len(left_parts), len(right_parts))):
        left_value, left_ok = _segment(left_parts, index)
        right_value, right_ok = _segment(right_parts, index)
        if left_ok != right_ok:
            return -1 if not left_ok else 1
        if left_value != right_value:
            return -1 if left_value < right_value else 1
    return 0


def _segment(parts, index):
    if index >= len(parts):
        return 0, True
    try:
        return int(parts[index].strip()), True
    except (TypeError, ValueError):
        return 0, False


class Command(BaseCommand):
    help = (
        "Report whether every installation in the fleet is past a given "
        "version — the gate on any contract migration."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--floor",
            required=True,
            help="The version the removal is safe past.",
        )
        parser.add_argument(
            "--quiet",
            action="store_true",
            help="Exit code only.",
        )

    def handle(self, *args, **options):
        from apps.core import relay

        floor = options["floor"]
        try:
            status = relay.fleet_status()
        except Exception as error:  # noqa: BLE001 — any failure holds the gate
            self.stderr.write(
                self.style.ERROR(
                    f"Could not ask the relay ({error}). The gate stays shut: "
                    "not knowing is not the same as being ready."
                )
            )
            raise SystemExit(2) from error

        minimum = (status or {}).get("minimum_version") or ""
        unknown = int((status or {}).get("unknown_version_count") or 0)
        count = int((status or {}).get("count") or 0)

        if count == 0:
            self.stderr.write(
                self.style.ERROR(
                    "The relay reported no installations. A fleet of nobody is "
                    "not a fleet that is ready."
                )
            )
            raise SystemExit(2)
        if unknown:
            self.stderr.write(
                self.style.ERROR(
                    f"{unknown} installation(s) have never reported a version. "
                    "A box that has not phoned home is the one most likely to "
                    "be running last year's build."
                )
            )
            raise SystemExit(1)
        if not minimum or compare_versions(minimum, floor) < 0:
            self.stderr.write(
                self.style.ERROR(
                    f"The fleet's minimum version is {minimum or 'unknown'}, "
                    f"behind {floor}. A contract migration shipped now would "
                    "run the behind installation against a schema it does not "
                    "know."
                )
            )
            raise SystemExit(1)

        if not options["quiet"]:
            self.stdout.write(
                self.style.SUCCESS(
                    f"Fleet minimum is {minimum}, past {floor} across "
                    f"{count} installation(s). A contract migration may ship."
                )
            )
        return None
