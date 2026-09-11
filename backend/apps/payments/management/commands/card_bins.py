"""List the card BINs a shop's receipts have actually seen.

Collecting BINs by hunting down one card per bank is slow and never finishes —
a bank holds several (one per scheme, per product, per portfolio). The shop's
own till has been recording them all along: every Moamalat receipt stores a
masked PAN like ``639974*********8809``, whose leading six digits are the BIN.

So this reads what is already there and reports which BINs the shop meets and
how often, busiest first. That turns "find every Libyan bank's BIN" into
"identify the eight prefixes this shop actually takes money from", which is a
morning's work instead of a project.

    python manage.py card_bins
    python manage.py card_bins --known 639974,639500   # hide the ones you have

Identifying a prefix still needs a human with a card in hand: nothing in a
receipt names the bank, and the online BIN databases do not carry Libyan
domestic cards at all. Add confirmed ones to ``bankBinRanges`` in
``frontend/lib/src/shared/payments/libyan_banks.dart``.
"""

from __future__ import annotations

import re
from collections import Counter

from django.core.management.base import BaseCommand

from apps.payments.models import Payment

# Only LEADING digits are a BIN. A provider that masks all but the last four
# (Madfoatech prints ``************5091``) reveals none, and reading its tail as
# a prefix would name an unrelated bank.
_LEADING_DIGITS = re.compile(r"^(\d{6,})")


class Command(BaseCommand):
    help = "List card BINs seen in stored receipts, busiest first."

    def add_arguments(self, parser):
        parser.add_argument(
            "--known",
            default="",
            help="Comma-separated BINs you have already identified; hidden from the report.",
        )
        parser.add_argument(
            "--limit",
            type=int,
            default=50,
            help="How many distinct BINs to show (default 50).",
        )

    def handle(self, *args, **options):
        known = {
            value.strip()
            for value in options["known"].split(",")
            if value.strip()
        }

        seen = Counter()
        masked_but_unreadable = 0
        total = 0

        rows = (
            Payment.objects.filter(method=Payment.Method.CARD)
            .exclude(card_receipt_data={})
            .values_list("card_receipt_data", flat=True)
            .iterator(chunk_size=2000)
        )
        for data in rows:
            pan = str((data or {}).get("masked_pan") or "").strip()
            if not pan:
                continue
            total += 1
            match = _LEADING_DIGITS.match(pan)
            if match is None:
                masked_but_unreadable += 1
                continue
            seen[match.group(1)[:6]] += 1

        if not total:
            self.stdout.write("No card receipts stored yet — nothing to read.")
            return

        unknown = [(bin_, n) for bin_, n in seen.most_common() if bin_ not in known]

        self.stdout.write(f"card receipts with a PAN : {total}")
        self.stdout.write(f"distinct BINs seen       : {len(seen)}")
        self.stdout.write(
            f"no BIN in the PAN        : {masked_but_unreadable} "
            "(acquirer masks all but the last four — never resolvable)"
        )
        if known:
            self.stdout.write(f"already identified       : {len(seen) - len(unknown)}")

        if not unknown:
            self.stdout.write(self.style.SUCCESS("\nEvery BIN this shop sees is identified."))
            return

        self.stdout.write("\nBINs still to identify, busiest first:\n")
        self.stdout.write(f"  {'BIN':<10} {'payments':>9}   share")
        for bin_, count in unknown[: options["limit"]]:
            share = count / total * 100
            self.stdout.write(f"  {bin_:<10} {count:>9}   {share:5.1f}%")
        self.stdout.write(
            "\nIdentify each from a card in hand, then add it to bankBinRanges in\n"
            "frontend/lib/src/shared/payments/libyan_banks.dart."
        )
