"""A document number that does not skip.

A primary key is *allowed* to have gaps, and PostgreSQL says so plainly: a
rolled-back insert keeps the value it took, and a crash discards whatever the
sequence had reserved but not yet handed out. Neither is a bug. Deriving a
customer-facing invoice number from that sequence is, because the number then
inherits every gap the key is permitted.

It happened. In one field week the shop's receipt series jumped five times, by
30, 31, 31, 31 and 32 — 155 numbers that were never issued to anyone — and each
jump landed on an unclean restart of the database. PostgreSQL pre-logs 32
sequence values to WAL at a time so that `nextval` does not have to write a WAL
record per call (``SEQ_LOG_VALS`` in ``src/backend/commands/sequence.c``), and
crash recovery resumes from that pre-logged high-water mark. The reservation is
refreshed after every checkpoint, so at this shop's rate — a sale every hundred
seconds, a checkpoint every five minutes — a crash always discarded almost the
whole batch. Reproduced exactly: consume one value, `SIGKILL` the server, and
the next value is 32 higher.

Where the paper ledger is what the shop actually trusts, a series that skips 32
is not a curiosity. Someone has to explain the missing invoices, and "the
database did it" is not an explanation anyone can check.

So the number comes from a counter row instead of a sequence. The difference
that matters is transactional: a counter row is ordinary data, so it rolls back
with the sale that took it and it is recovered with the sale that kept it. A
sequence is deliberately neither.

The cost is honest and small: allocating takes a row lock held until the sale
commits, so sales are numbered one at a time. That is the definition of gapless
— there is no way to promise a number is never skipped while handing two of them
out at once — and at a till it is free. A checkout settles in about 300ms, so
the ceiling is a few sales a second on a shop that rings up one every hundred.
"""

from __future__ import annotations

from django.db import models, transaction


class DocumentNumberSeries(models.Model):
    """The last number issued in one series.

    Keyed by a string rather than a foreign key so a series can exist before
    anything numbered from it does, and so the table stays one row per series
    however many document types end up using it.
    """

    key = models.CharField(max_length=64, primary_key=True)
    last_value = models.PositiveBigIntegerField(default=0)

    class Meta:
        verbose_name_plural = "document number series"

    def __str__(self) -> str:
        return f"{self.key}: {self.last_value}"


#: The customer-facing sales series — what is printed on a receipt and written
#: in the shop's own ledger.
SALE_ORDER_SERIES = "sale_order"

#: What a supplier is quoted and invoices against.
PURCHASE_ORDER_SERIES = "purchase_order"

#: Internal, but an audit document all the same: a transfer number is how a
#: count discrepancy is traced back to the movement that caused it.
STOCK_TRANSFER_SERIES = "stock_transfer"

#: سند استلام أمانة — signed by two people and kept by both, so a hole in the
#: series is a page somebody can claim was torn out.
CONSIGNMENT_AGREEMENT_SERIES = "consignment_agreement"

#: سند صرف أمانة — the receipt a consignor signs for their money.
CONSIGNOR_PAYOUT_SERIES = "consignor_payout"


def next_document_number(key: str) -> int:
    """The next number in [key], reserved for this transaction only.

    Must be called inside the transaction that writes the document. The lock
    this takes is released at that transaction's commit, and if it rolls back
    so does the number — which is the whole point, and the reason this cannot
    be a sequence.
    """
    with transaction.atomic():
        series = _locked(key)
        if series is None:
            # Seeded by migration, so this is the path for a series nobody has
            # declared yet rather than the ordinary one. Created and then
            # re-read under the lock: `get_or_create` does not take one, and
            # two callers arriving together must not both start from zero.
            DocumentNumberSeries.objects.get_or_create(pk=key)
            series = _locked(key)
        series.last_value += 1
        series.save(update_fields=["last_value"])
        return series.last_value


def _locked(key: str) -> DocumentNumberSeries | None:
    return (
        DocumentNumberSeries.objects.select_for_update().filter(pk=key).first()
    )
