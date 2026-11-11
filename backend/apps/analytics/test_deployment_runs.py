"""Updates and installs become tracked events — once each, whatever arrives."""

import io
from unittest import mock

from django.core.management import call_command
from django.test import TestCase

from apps.analytics.deployment import record_deployment_runs
from apps.analytics.models import AnalyticsEvent


def _run(**overrides):
    record = {
        "id": "0b9f6c1e-run-1",
        "kind": "update",
        "trigger": "agent",
        "from_version": "0.9.0",
        "to_version": "0.9.1",
        "strategy": "live",
        "outcome": "succeeded",
        "error": "",
        "started_at": "2026-11-10T08:00:00Z",
        "finished_at": "2026-11-10T08:03:20Z",
        "duration_seconds": 200,
        "downtime_seconds": 0,
        "longest_outage_seconds": 0,
        "probe_samples": 198,
        "phases": {"backup": 12, "prepare": 1, "standby_ready": 150, "promote": 30},
    }
    record.update(overrides)
    return record


class DeploymentRunTests(TestCase):
    def test_an_update_is_tracked_with_what_it_cost(self):
        self.assertEqual(record_deployment_runs([_run()]), 1)
        event = AnalyticsEvent.objects.get(name="deployment.update")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.PERFORMANCE)
        self.assertEqual(event.source, AnalyticsEvent.Source.BACKEND)
        self.assertEqual(event.severity, AnalyticsEvent.Severity.INFO)
        self.assertEqual(event.app_version, "0.9.1")
        self.assertEqual(event.entity_type, "deployment_run")
        self.assertEqual(event.entity_id, "0b9f6c1e-run-1")
        self.assertEqual(event.occurred_at.isoformat(), "2026-11-10T08:03:20+00:00")
        self.assertEqual(event.attributes["from_version"], "0.9.0")
        self.assertEqual(event.attributes["strategy"], "live")
        self.assertEqual(event.attributes["trigger"], "agent")
        self.assertEqual(event.metrics["duration_seconds"], 200)
        self.assertEqual(event.metrics["downtime_seconds"], 0)
        self.assertEqual(event.metrics["phase_standby_ready_seconds"], 150)

    def test_the_same_run_arriving_again_is_not_a_second_event(self):
        """The host re-sends until it hears the run landed."""
        record_deployment_runs([_run()])
        self.assertEqual(record_deployment_runs([_run(), _run(id="run-2")]), 1)
        self.assertEqual(AnalyticsEvent.objects.filter(entity_type="deployment_run").count(), 2)

    def test_the_same_run_twice_in_one_batch_is_one_event(self):
        self.assertEqual(record_deployment_runs([_run(), _run()]), 1)

    def test_an_unmeasured_downtime_is_absent_not_zero(self):
        """An install has no probe; claiming zero downtime would be a lie."""
        record_deployment_runs(
            [
                _run(
                    kind="install",
                    downtime_seconds=None,
                    longest_outage_seconds=None,
                    from_version="",
                )
            ]
        )
        event = AnalyticsEvent.objects.get(name="deployment.install")
        self.assertNotIn("downtime_seconds", event.metrics)
        self.assertNotIn("from_version", event.attributes)

    def test_how_it_ended_sets_how_loud_the_event_is(self):
        record_deployment_runs(
            [
                _run(id="a", outcome="aborted"),
                _run(id="b", outcome="rolled_back", error="health check failed"),
                _run(id="c", outcome="failed"),
            ]
        )
        severity = dict(AnalyticsEvent.objects.values_list("entity_id", "severity"))
        self.assertEqual(
            severity,
            {
                "a": AnalyticsEvent.Severity.WARNING,
                "b": AnalyticsEvent.Severity.ERROR,
                "c": AnalyticsEvent.Severity.CRITICAL,
            },
        )
        self.assertEqual(
            AnalyticsEvent.objects.get(entity_id="b").attributes["error"], "health check failed"
        )

    def test_what_is_not_a_run_is_ignored(self):
        junk = [None, "text", {}, {"id": "x", "kind": "reboot"}, {"kind": "update"}]
        self.assertEqual(record_deployment_runs(junk), 0)
        self.assertFalse(AnalyticsEvent.objects.exists())

    def test_odd_numbers_and_phase_names_never_reach_the_metrics(self):
        record_deployment_runs(
            [
                _run(
                    duration_seconds=-5,
                    probe_samples=True,
                    phases={"ok": 3, "bad name": 4, "neg": -1},
                )
            ]
        )
        metrics = AnalyticsEvent.objects.get().metrics
        self.assertNotIn("duration_seconds", metrics)
        self.assertNotIn("probe_samples", metrics)
        self.assertEqual(metrics["phase_ok_seconds"], 3)
        self.assertNotIn("phase_bad name_seconds", metrics)
        self.assertNotIn("phase_neg_seconds", metrics)


class RecordDeploymentRunsCommandTests(TestCase):
    def _call(self, text):
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO(text)):
            call_command("record_deployment_runs", stdout=out)
        return out.getvalue()

    def test_json_lines_on_stdin_become_events(self):
        import json

        text = json.dumps(_run()) + "\n\n" + json.dumps(_run(id="run-2", kind="install")) + "\n"
        self.assertIn("2 recorded", self._call(text))
        self.assertEqual(AnalyticsEvent.objects.count(), 2)

    def test_a_broken_line_does_not_hold_back_the_ones_after_it(self):
        import json

        text = '{"id": "half\n' + json.dumps(_run()) + "\n"
        self.assertIn("1 recorded, 1 skipped", self._call(text))
        self.assertEqual(AnalyticsEvent.objects.count(), 1)
