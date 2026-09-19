"""The gate on any contract migration: is the whole fleet past a version?

``zero-downtime-updates`` runs the previous release against the new schema for
about a minute, and ``relay-remote-update`` lets shops sit pinned, paused or
on a canary — so "has everybody moved on" is a real question with a real
answer, and this is where it stops being a hope.

Every test here is about the gate **refusing**. That is deliberate: the
failure it prevents is shipping a removal over the top of one pinned shop, and
a gate that is only tested when it opens is a gate nobody has tested.
"""

from io import StringIO
from unittest.mock import patch

from django.core.management import call_command
from django.test import SimpleTestCase

from apps.core.management.commands.check_fleet_minimum_version import (
    compare_versions,
)


def _run(**status):
    out, err = StringIO(), StringIO()
    with patch("apps.core.relay.fleet_status", return_value=status):
        try:
            call_command(
                "check_fleet_minimum_version",
                floor="2.12.0",
                stdout=out,
                stderr=err,
            )
        except SystemExit as exit_code:
            return int(exit_code.code), out.getvalue(), err.getvalue()
    return 0, out.getvalue(), err.getvalue()


class TheGateRefusesUnlessItIsSureTests(SimpleTestCase):
    def test_a_fleet_past_the_floor_may_ship(self):
        code, out, _ = _run(
            minimum_version="2.13.1", unknown_version_count=0, count=12
        )
        self.assertEqual(code, 0)
        self.assertIn("2.13.1", out)

    def test_one_shop_behind_holds_it_shut(self):
        code, _, err = _run(
            minimum_version="2.11.9", unknown_version_count=0, count=12
        )
        self.assertEqual(code, 1)
        self.assertIn("2.11.9", err)

    def test_a_silent_installation_holds_it_shut(self):
        """A box that has not phoned home is the one most likely to be old."""
        code, _, err = _run(
            minimum_version="2.13.0", unknown_version_count=1, count=12
        )
        self.assertEqual(code, 1)
        self.assertIn("never reported", err)

    def test_a_relay_that_cannot_be_reached_holds_it_shut(self):
        out, err = StringIO(), StringIO()
        with patch(
            "apps.core.relay.fleet_status", side_effect=RuntimeError("no route")
        ):
            with self.assertRaises(SystemExit) as caught:
                call_command(
                    "check_fleet_minimum_version",
                    floor="2.12.0",
                    stdout=out,
                    stderr=err,
                )
        self.assertEqual(int(caught.exception.code), 2)
        self.assertIn("not knowing", err.getvalue())

    def test_an_empty_fleet_is_not_a_ready_fleet(self):
        code, _, err = _run(minimum_version="", unknown_version_count=0, count=0)
        self.assertEqual(code, 2)
        self.assertIn("no installations", err)


class VersionsCompareNumericallyTests(SimpleTestCase):
    def test_nine_sorts_before_ten(self):
        """As text, "2.9.4" sorts *after* "2.10.1" — and a gate that believed
        that would ship the drop over the one shop that is actually behind."""
        self.assertLess(compare_versions("2.9.4", "2.10.1"), 0)

    def test_equal_to_the_floor_is_past_it(self):
        self.assertEqual(compare_versions("2.12.0", "2.12.0"), 0)

    def test_a_shorter_version_is_padded_rather_than_truncated(self):
        self.assertEqual(compare_versions("2.12", "2.12.0"), 0)
        self.assertLess(compare_versions("2.12", "2.12.1"), 0)

    def test_an_unparseable_version_behaves_like_an_old_one(self):
        self.assertLess(compare_versions("dev", "1.0.0"), 0)
