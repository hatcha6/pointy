"""The currency registry and the rate table.

Two models, both small, both reference data:

:class:`Currency`
    What currencies exist, how they are rendered, and to how many places they
    round. Keyed on the ISO 4217 code because that is what the feed speaks and
    what a foreign key reads best (``pricing_currency_id == "USD"``).

:class:`ExchangeRate`
    One published rate: *this many ``to_currency`` per one ``from_currency``, at
    this instant, for this settlement instrument, from this source*. Rows are
    append-only in spirit — a new rate is a new row with a later
    ``effective_at``, never an edit of the old one — because a document that
    froze yesterday's rate must still be able to find it. ``apps.fx.rates``
    is the only supported way to read one.

The rate table is deliberately *not* keyed on a date. Parallel-market rates move
several times a day, so the resolver asks "what was the rate as of this instant"
and takes the newest row at or before it, the way ERPNext's ``Currency Exchange``
lookup is on-or-before the transaction date rather than "latest".
"""

from __future__ import annotations

from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models

from apps.core.models import TimeStampedModel

from . import currencies as ref
from .money import CurrencySpec


class Currency(models.Model):
    """A currency this shop can price or settle in."""

    code = models.CharField(max_length=8, primary_key=True)
    name_en = models.CharField(max_length=64)
    name_ar = models.CharField(max_length=64)
    symbol_en = models.CharField(max_length=8, blank=True, default="")
    symbol_ar = models.CharField(max_length=8, blank=True, default="")
    # Capped at 2 by ``money.exponent_for``: every money column in this product
    # is ``decimal_places=2``, so a wider currency could not be stored. See
    # ``currencies`` for why LYD and TND carry two rather than ISO 4217's three.
    decimals = models.PositiveSmallIntegerField(default=ref.BUILTIN_DECIMALS)
    display_order = models.PositiveIntegerField(default=0)
    # A shop that never trades in liras should not scroll past them in a picker.
    # Disabling is never deletion: an existing price or frozen rate keeps its
    # currency row, so history stays readable.
    is_enabled = models.BooleanField(default=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name_plural = "currencies"
        ordering = ["display_order", "code"]

    def __str__(self) -> str:
        return self.code

    def save(self, *args, **kwargs):
        self.code = str(self.code or "").strip().upper()
        return super().save(*args, **kwargs)

    def to_spec(self) -> CurrencySpec:
        """Adapt this row into a persistence-free :class:`CurrencySpec`.

        Mirrors ``holidays.Holiday.to_definition``: the arithmetic layer never
        touches a model, so it stays unit-testable without a database.
        """
        return CurrencySpec(
            code=self.code,
            decimals=self.decimals,
            symbol_ar=self.symbol_ar,
            symbol_en=self.symbol_en,
        )

    def name(self, language: str = "ar") -> str:
        return self.name_ar if str(language).startswith("ar") else self.name_en


class ExchangeRate(TimeStampedModel):
    """One published exchange rate, at one instant, for one settlement instrument.

    ``rate`` reads as *how many ``to_currency`` units per one ``from_currency``
    unit* — USD to LYD at 6.85 means one dollar buys 6.85 dinars. The ``from``/
    ``to`` naming is load-bearing; see ``apps.fx.money`` for why "base"/"quote"
    is avoided.
    """

    INSTRUMENT_CHOICES = [
        (ref.INSTRUMENT_CASH, ref.INSTRUMENT_LABELS_EN[ref.INSTRUMENT_CASH]),
        (ref.INSTRUMENT_BANK, ref.INSTRUMENT_LABELS_EN[ref.INSTRUMENT_BANK]),
    ]
    SOURCE_CHOICES = [(value, value) for value in ref.SOURCES]

    from_currency = models.ForeignKey(
        Currency,
        on_delete=models.PROTECT,
        related_name="rates_from",
    )
    to_currency = models.ForeignKey(
        Currency,
        on_delete=models.PROTECT,
        related_name="rates_to",
    )
    # Both values are parallel-market rates; this says how the money moves, not
    # which market it came from. See ``apps.fx.currencies``.
    instrument = models.CharField(
        max_length=8,
        choices=INSTRUMENT_CHOICES,
        default=ref.INSTRUMENT_CASH,
    )
    # Only meaningful for a bank settlement — the feed publishes a separate
    # series per bank because the price differs between them. Normalised to ""
    # for cash in ``save`` so it can never fragment the uniqueness key.
    bank_code = models.CharField(max_length=32, blank=True, default="")
    effective_at = models.DateTimeField(db_index=True)
    rate = models.DecimalField(
        max_digits=18,
        decimal_places=8,
        validators=[MinValueValidator(0)],
    )
    source = models.CharField(
        max_length=16,
        choices=SOURCE_CHOICES,
        default=ref.SOURCE_RELAY,
    )
    relay_id = models.CharField(max_length=80, blank=True, default="")
    # Why the owner typed this rate. Only ever set on a manual row, and shown
    # beside it, so a number that overrides the feed can explain itself.
    note = models.CharField(max_length=240, blank=True, default="")
    entered_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="entered_exchange_rates",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-effective_at", "from_currency_id"]
        constraints = [
            models.UniqueConstraint(
                fields=[
                    "from_currency",
                    "to_currency",
                    "instrument",
                    "bank_code",
                    "effective_at",
                ],
                name="fx_rate_unique_per_instant",
            ),
            models.CheckConstraint(
                condition=models.Q(rate__gt=0),
                name="fx_rate_positive",
            ),
            # A bank code on a cash rate is meaningless, and would split the
            # uniqueness key into two rows that both claim the same instant.
            models.CheckConstraint(
                condition=models.Q(instrument=ref.INSTRUMENT_BANK)
                | models.Q(bank_code=""),
                name="fx_rate_bank_code_only_for_bank",
            ),
        ]
        indexes = [
            # The resolver's only query shape: newest row at or before an
            # instant, for one pair and one instrument. Descending on
            # ``effective_at`` so the lookup is a single index step, not a sort.
            models.Index(
                fields=[
                    "from_currency",
                    "to_currency",
                    "instrument",
                    "bank_code",
                    "-effective_at",
                ],
                name="fx_rate_lookup_idx",
            ),
        ]

    def __str__(self) -> str:
        return (
            f"1 {self.from_currency_id} = {self.rate} {self.to_currency_id} "
            f"({self.instrument}{'/' + self.bank_code if self.bank_code else ''})"
        )

    def save(self, *args, **kwargs):
        # Normalising here rather than only in the service layer keeps the check
        # constraint satisfiable no matter which path writes the row — the sync,
        # the admin, a fixture, or a test.
        self.instrument = ref.normalize_instrument(self.instrument)
        self.bank_code = ref.normalize_bank_code(
            self.bank_code, instrument=self.instrument
        )
        return super().save(*args, **kwargs)
