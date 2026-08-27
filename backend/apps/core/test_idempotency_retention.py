from datetime import timedelta

from django.test import TestCase
from django.utils import timezone

from .idempotency import purge_expired_idempotency_records
from .models import IdempotencyRecord


class IdempotencyRetentionTests(TestCase):
    """The table only ever grew: 28,406 rows in the field, zero replays.

    A record exists so a retried write is recognised as the same write, and
    that window is measured in seconds. Keeping them forever is write
    amplification plus a stored JSON response body per row.
    """

    def _record(self, key, age):
        record = IdempotencyRecord.objects.create(
            key=key,
            owner_key="user:1",
            method="POST",
            path="/api/sales/orders/",
            request_hash="abc",
            response_status_code=201,
            response_data={"id": 1},
        )
        IdempotencyRecord.objects.filter(pk=record.pk).update(
            created_at=timezone.now() - age
        )
        return record

    def test_deletes_records_past_the_window(self):
        self._record("old", timedelta(days=5))
        self._record("older", timedelta(days=30))

        deleted = purge_expired_idempotency_records()

        self.assertEqual(deleted, 2)
        self.assertEqual(IdempotencyRecord.objects.count(), 0)

    def test_keeps_records_a_retry_could_still_match(self):
        # The whole point of the table: a till retrying a checkout through a
        # flaky link must still be recognised rather than billing twice.
        self._record("fresh", timedelta(minutes=5))

        purge_expired_idempotency_records()

        self.assertEqual(IdempotencyRecord.objects.count(), 1)

    def test_window_is_configurable(self):
        self._record("recent", timedelta(hours=2))

        purge_expired_idempotency_records(retention=timedelta(hours=1))

        self.assertEqual(IdempotencyRecord.objects.count(), 0)

    def test_purging_an_empty_table_is_harmless(self):
        self.assertEqual(purge_expired_idempotency_records(), 0)
