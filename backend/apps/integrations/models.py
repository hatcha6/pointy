"""The shop's account with an outside service it resells.

One row per provider the shop has actually configured. The *list* of providers
is static (see :mod:`apps.integrations.catalog`); this model holds only what a
particular shop typed in — where the provider lives, who it logs in as, and the
password, encrypted.

The health columns exist because a credential that has silently stopped working
is the failure a cashier meets at the worst moment: mid-sale, with a customer
waiting. Probing writes what it learned here, so Shop Settings can say "last
checked at 09:14, balance 25.00" instead of "configured" and nothing else.
"""

from __future__ import annotations

from django.db import models

from apps.core.models import TimeStampedModel
from apps.core.secret_box import SecretBox, SecretStorageMixin

from . import catalog

SECRET_BOX = SecretBox("POINTY_INTEGRATIONS_SECRET_KEY")


class IntegrationAccount(SecretStorageMixin, TimeStampedModel):
    """A shop's credentials for one resale provider."""

    secret_box = SECRET_BOX

    # One account per provider. A shop has a single agency login with HD Box,
    # and the settings screen is a list of providers rather than of accounts.
    # Lift this constraint the day a shop genuinely holds two agency codes.
    provider = models.CharField(
        max_length=32, choices=catalog.PROVIDER_CHOICES, unique=True
    )
    base_url = models.CharField(max_length=255, blank=True)
    username = models.CharField(max_length=120, blank=True)
    secrets_encrypted = models.TextField(blank=True, editable=False)
    config = models.JSONField(default=dict, blank=True)
    is_active = models.BooleanField(default=True)

    # --- health, written by services.probe_account -------------------------
    last_checked_at = models.DateTimeField(blank=True, null=True)
    last_connected_at = models.DateTimeField(blank=True, null=True)
    last_error = models.TextField(blank=True)
    last_error_code = models.CharField(max_length=40, blank=True)
    last_error_at = models.DateTimeField(blank=True, null=True)

    # The agency's prepaid float, in LYD. HD Box renders it with a "$" glyph
    # and it is not dollars — see catalog.ProviderSpec.currency before anyone
    # is tempted to convert it.
    balance = models.DecimalField(
        max_digits=12, decimal_places=2, blank=True, null=True
    )
    balance_at = models.DateTimeField(blank=True, null=True)
    # What the provider calls this account (its own label for the agency).
    account_label = models.CharField(max_length=120, blank=True)

    # The FALLBACK margin, used only for an option the shop has not priced by
    # hand (see IntegrationOptionPrice). Real shops do not mark up by a single
    # rule: one field agency sells the provider's 25/65/125/220 ladder at
    # 30/80/140/240, which is neither a fixed amount nor a fixed percentage.
    # So the per-option list is the real answer and this is what a brand-new
    # option falls back to until somebody prices it.
    #
    # It lives on the account rather than being typed at the till: apps.sales
    # never trusts a client-sent price, and the owner — not the cashier —
    # decides the margin. Default is none, so a shop that has not thought
    # about it resells at cost rather than at a number Pointy invented.
    class Markup(models.TextChoices):
        NONE = "none", "Sell at cost"
        PERCENT = "percent", "Percentage on top"
        AMOUNT = "amount", "Fixed amount on top"

    markup_kind = models.CharField(
        max_length=8, choices=Markup.choices, default=Markup.NONE
    )
    markup_value = models.DecimalField(max_digits=8, decimal_places=2, default=0)

    # Where this provider's float lives in the shop's money position. Created
    # the first time a top-up is recorded, so a shop that never tops up never
    # grows an empty account it has to look at.
    money_account = models.OneToOneField(
        "treasury.MoneyAccount",
        on_delete=models.SET_NULL,
        related_name="integration_account",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["provider"]
        permissions = [
            ("manage_integrations", "Can configure resale provider accounts"),
            ("use_integrations", "Can look up and recharge on a provider account"),
            # Separate from manage_integrations on purpose. The person who
            # walks to the provider's office and pays for a float top-up is
            # almost never the owner, and gating the record on the right to
            # configure the account meant the one member of staff who knows
            # the top-up happened is the one who cannot write it down.
            (
                "record_integration_topup",
                "Can record money paid into a provider float",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.provider} ({self.username})" if self.username else self.provider

    @property
    def spec(self) -> catalog.ProviderSpec | None:
        return catalog.spec_for(self.provider)

    @property
    def password(self) -> str:
        return self.get_secret(catalog.FIELD_PASSWORD)

    @property
    def is_configured(self) -> bool:
        """Every required credential present — not a claim that it still works."""
        spec = self.spec
        if spec is None:
            return False
        for field in spec.fields:
            if field in spec.secret_fields:
                if not self.has_secret(field):
                    return False
            elif not (getattr(self, field, "") or "").strip():
                return False
        return True

    def resolved_base_url(self) -> str:
        spec = self.spec
        default = spec.default_base_url if spec else ""
        return (self.base_url or default).rstrip("/")

    def selling_price(self, cost, option_code: str = "", *, prices=None):
        """What the customer pays for a top-up that costs the float ``cost``.

        Four sources, in order: the price the owner set for **this option**,
        the provider's recommended retail for it, the account's fallback
        markup, then cost itself.

        Rounded to two places at the end, never per-step, and never below
        cost — a price that computes to less than the provider charges is a
        configuration mistake or a cost rise nobody noticed, not an
        instruction to sell at a loss. The settings screen surfaces the
        difference rather than leaving it silent.

        ``prices`` lets a caller pass an already-loaded ``{option_code: price}``
        map so pricing a whole ladder is one query rather than one per option.
        """
        from decimal import ROUND_HALF_UP, Decimal

        cost = Decimal(cost)
        floor = cost.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

        override = None
        if option_code:
            if prices is not None:
                override = prices.get(option_code)
            else:
                row = self.option_prices.filter(option_code=option_code).first()
                override = row.effective_price if row else None
        if override is not None:
            return max(
                Decimal(override).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP),
                floor,
            )

        if self.markup_kind == self.Markup.PERCENT:
            price = cost * (Decimal("1") + (self.markup_value / Decimal("100")))
        elif self.markup_kind == self.Markup.AMOUNT:
            price = cost + self.markup_value
        else:
            price = cost
        return max(price.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP), floor)

    def option_price_map(self) -> dict:
        """``{option_code: price}`` for every option that has a price at all.

        Includes rows priced only by the provider's recommendation, because
        that is what a sale of them would charge.
        """
        return {
            row.option_code: row.effective_price
            for row in self.option_prices.all()
            if row.effective_price is not None
        }


class IntegrationFulfillment(TimeStampedModel):
    """A recharge sold on an order line, and what the provider did about it.

    A top-up is two facts that must not be confused: the shop **sold** it (an
    order line, money in the drawer) and the provider **performed** it (time on
    somebody's card, money out of the float). Pointy has always had the first.
    This model holds the second, next to the line that sold it, so the gap
    between them is visible instead of assumed.

    ``status`` starts at ``pending`` and stays there until a write path exists.
    That is deliberate, not unfinished: the provider's API is not idempotent, so
    a sale can be recorded honestly as "sold, not yet performed" rather than
    have Pointy guess. Reconciliation against the provider's own purchase log
    is what moves a row to ``confirmed``.
    """

    class Status(models.TextChoices):
        PENDING = "pending", "Sold, not yet sent to the provider"
        SUBMITTED = "submitted", "Sent, awaiting confirmation"
        CONFIRMED = "confirmed", "Seen in the provider's own log"
        FAILED = "failed", "The provider refused it"
        CANCELLED = "cancelled", "The sale was voided"

    order_line = models.OneToOneField(
        "sales.OrderLine",
        on_delete=models.CASCADE,
        related_name="integration_fulfillment",
    )
    account = models.ForeignKey(
        IntegrationAccount,
        on_delete=models.PROTECT,
        related_name="fulfillments",
    )
    provider = models.CharField(max_length=32, choices=catalog.PROVIDER_CHOICES)

    # What was bought, in the provider's own vocabulary.
    subscriber_ref = models.CharField(max_length=64, db_index=True)  # the card number
    #: The card's own record, so an invoice can name the customer months
    #: later without matching on a string.
    subscriber = models.ForeignKey(
        "IntegrationSubscriber",
        on_delete=models.SET_NULL,
        related_name="fulfillments",
        blank=True,
        null=True,
    )
    option_code = models.CharField(max_length=64)                    # "renew:12"
    option_label = models.CharField(max_length=160, blank=True)
    months = models.PositiveIntegerField(default=0)
    package_id = models.CharField(max_length=32, blank=True)
    package_name = models.CharField(max_length=160, blank=True)

    # What it costs the shop, in LYD, as quoted at the moment of sale. This is
    # the float draw-down, and it is what lands in OrderLine.unit_cost — the
    # selling price is the line's own and may carry the shop's margin.
    cost = models.DecimalField(max_digits=12, decimal_places=2)

    status = models.CharField(
        max_length=16, choices=Status.choices, default=Status.PENDING, db_index=True
    )
    # The provider's own id for the purchase, once reconciliation finds it.
    provider_reference = models.CharField(max_length=64, blank=True, db_index=True)
    # The provider's receipt exactly as it gave it to us, so the shop can print
    # the original beside Pointy's invoice rather than a retyped version.
    provider_receipt = models.JSONField(default=dict, blank=True)

    submitted_at = models.DateTimeField(blank=True, null=True)
    confirmed_at = models.DateTimeField(blank=True, null=True)
    last_error = models.TextField(blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["provider", "subscriber_ref"]),
            models.Index(fields=["status", "created_at"]),
        ]

    def __str__(self) -> str:
        return f"{self.provider}:{self.subscriber_ref} ({self.status})"

    @property
    def is_settled(self) -> bool:
        return self.status in {self.Status.CONFIRMED, self.Status.CANCELLED}


class IntegrationOptionPrice(models.Model):
    """What this shop charges for one thing the provider sells.

    The row exists as soon as an option is *seen* — every card lookup records
    the options it was quoted — because the price ladder is only available
    per-card (HD Box renders it inside the renew form for a specific
    subscriber), so there is no catalog to read in Shop Settings. Learning it
    from real lookups is what lets an owner price a list that is actually
    theirs instead of one Pointy guessed at.

    ``price`` stays null until somebody sets it; until then the account's
    fallback markup applies. ``last_cost`` is the most recent figure the
    provider quoted, kept so the settings screen can show a margin — and show
    it going wrong when a provider raises a price, which HD Box did between
    2024 and 2026.
    """

    account = models.ForeignKey(
        IntegrationAccount, on_delete=models.CASCADE, related_name="option_prices"
    )
    option_code = models.CharField(max_length=64)
    label = models.CharField(max_length=160, blank=True)
    kind = models.CharField(max_length=16, blank=True)
    months = models.PositiveIntegerField(default=0)
    package_name = models.CharField(max_length=160, blank=True)

    #: What the shop charges. Null = fall back to the suggestion, then markup.
    price = models.DecimalField(
        max_digits=12, decimal_places=2, blank=True, null=True
    )
    #: What the provider recommends charging, snapshotted from the catalog
    #: when the option was first seen. Kept on the row rather than read from
    #: the catalog each time so a shop can see what it was told even after we
    #: update the reference data.
    suggested_price = models.DecimalField(
        max_digits=12, decimal_places=2, blank=True, null=True
    )
    #: The provider's most recent quote for this option.
    last_cost = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    last_seen_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["kind", "months", "option_code"]
        constraints = [
            models.UniqueConstraint(
                fields=["account", "option_code"],
                name="integrations_unique_option_price",
            )
        ]

    def __str__(self) -> str:
        return f"{self.account.provider}:{self.option_code}"

    @property
    def effective_price(self):
        """What a sale of this option actually charges, before the cost floor.

        The shop's own price wins; otherwise the provider's recommendation;
        otherwise nothing, and the account's markup takes over.
        """
        return self.price if self.price is not None else self.suggested_price

    @property
    def is_suggested(self) -> bool:
        """Charging the provider's recommendation rather than a chosen price."""
        return self.price is None and self.suggested_price is not None

    @property
    def margin(self):
        effective = self.effective_price
        if effective is None:
            return None
        return effective - self.last_cost

    @property
    def is_below_cost(self) -> bool:
        """The provider now charges more than this row would sell it for."""
        effective = self.effective_price
        return effective is not None and effective < self.last_cost


class IntegrationSubscriber(TimeStampedModel):
    """A card the shop has served, and who it belongs to.

    The provider will not tell us who the subscriber is — HD Box masks the
    name and phone from an agency login — so identity is Pointy's half of the
    bargain and the subscription is theirs. A cashier says "this card is
    Ahmed" once, and from then on every recharge of it attributes to Ahmed:
    his history, his RFM rank, his reminder when the card is about to lapse.

    Everything else here is a *snapshot* of what the provider last said,
    refreshed on each lookup. It is cache, not truth — the provider remains
    the authority — but it is what lets the shop see a lapsed regular without
    a round trip, and what the invoice prints months later when the card's
    live state has moved on.
    """

    account = models.ForeignKey(
        IntegrationAccount, on_delete=models.CASCADE, related_name="subscribers"
    )
    provider = models.CharField(max_length=32, choices=catalog.PROVIDER_CHOICES)
    subscriber_ref = models.CharField(max_length=64, db_index=True)

    #: The person, once somebody says who it is.
    customer = models.ForeignKey(
        "customers.Customer",
        on_delete=models.SET_NULL,
        related_name="integration_subscribers",
        blank=True,
        null=True,
    )
    #: A name typed at the till for a card whose owner is not a Pointy
    #: customer. Cheaper than forcing a customer record on a walk-in, and it
    #: still puts a name on next month's renewal.
    display_name = models.CharField(max_length=160, blank=True)
    note = models.CharField(max_length=255, blank=True)

    # --- snapshot of what the provider last told us ------------------------
    package_name = models.CharField(max_length=160, blank=True)
    device_model = models.CharField(max_length=120, blank=True)
    provider_status = models.CharField(max_length=64, blank=True)
    price_per_month = models.DecimalField(
        max_digits=12, decimal_places=2, blank=True, null=True
    )
    activated_at = models.DateTimeField(blank=True, null=True)
    expire_at = models.DateTimeField(blank=True, null=True, db_index=True)
    card_balance = models.DecimalField(
        max_digits=12, decimal_places=2, blank=True, null=True
    )
    #: Across every agency, not just this shop — which is exactly what makes
    #: it worth showing: it says how much of this customer somebody else has.
    purchase_count = models.PositiveIntegerField(default=0)
    lifetime_spend = models.DecimalField(
        max_digits=12, decimal_places=2, blank=True, null=True
    )
    last_synced_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-updated_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["account", "subscriber_ref"],
                name="integrations_unique_subscriber",
            )
        ]
        indexes = [models.Index(fields=["provider", "subscriber_ref"])]

    def __str__(self) -> str:
        return f"{self.provider}:{self.subscriber_ref}"

    @property
    def label(self) -> str:
        """Who to show. The linked customer wins over a typed name."""
        if self.customer_id is not None:
            return self.customer.full_name
        return self.display_name

    @property
    def is_identified(self) -> bool:
        return bool(self.customer_id or self.display_name)
