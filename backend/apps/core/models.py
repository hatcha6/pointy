from datetime import time
from decimal import Decimal

from django.conf import settings as django_settings
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.utils import timezone

# Terms vocabulary only — that module imports no models at import time, so the
# settings model can name the basis without a cycle back through customers.
from apps.customers.payment_terms import MAX_CREDIT_DAYS, PaymentTermsBasis

# Pure reference data (no Django imports, and no import of this module), so
# core can read the settlement-instrument vocabulary without a circular
# dependency on the fx app's models.
from apps.fx import currencies as fx_ref


class TimeStampedModel(models.Model):
    # Indexed because nearly every list, dashboard, and report query filters or
    # orders on created_at; without this they full-scan + filesort as data grows.
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class IdempotencyRecord(TimeStampedModel):
    key = models.CharField(max_length=180)
    owner_key = models.CharField(max_length=128, db_index=True)
    method = models.CharField(max_length=12)
    path = models.CharField(max_length=512)
    request_hash = models.CharField(max_length=64)
    response_status_code = models.PositiveSmallIntegerField(blank=True, null=True)
    response_data = models.JSONField(blank=True, null=True)
    replay_count = models.PositiveIntegerField(default=0)
    completed_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["owner_key", "method", "path", "key"],
                name="unique_idempotency_record_per_request_scope",
            )
        ]
        indexes = [
            models.Index(fields=["owner_key", "key"]),
            models.Index(fields=["method", "path"]),
        ]

    def __str__(self):
        return f"{self.owner_key} {self.method} {self.path} {self.key}"


class ShopSettingsQuerySet(models.QuerySet):
    def update(self, **kwargs):
        # ``.filter(pk=1).update(...)`` skips post_save, so it must drop the
        # cached singleton itself or a stale copy survives until the TTL.
        rows = super().update(**kwargs)
        from apps.core import caching, state_version

        caching.invalidate_shop_settings()
        # ...and tell every client, for the same reason: a setting written this
        # way is still a setting every till is showing.
        state_version.bump("settings")
        return rows


class ShopSettings(TimeStampedModel):
    class ShopType(models.TextChoices):
        GENERAL = "general", "General retail"
        RESTAURANT = "restaurant", "Restaurant / Café"
        GROCERY = "grocery", "Grocery / Supermarket"
        PHARMACY = "pharmacy", "Pharmacy"
        PHONE_REPAIR = "phone_repair", "Phone shop & repair"
        CAR_WORKSHOP = "car_workshop", "Car workshop"
        BAKERY = "bakery", "Bakery / Pastry"
        RETAIL = "retail", "Clothing / Retail"

    class ValuationMethod(models.TextChoices):
        """How the cost of goods sold is decided when stock was bought at more
        than one price. Mirrors ``apps.inventory.valuation.ValuationMethod``.

        This is close to irreversible in practice: the method decides what every
        past sale's cost *was*, so switching it mid-life re-labels history that
        has already been reported, banked on, and paid commission against. The
        API refuses a change once stock has moved unless the caller explicitly
        acknowledges that (see ``ShopSettingsSerializer``).
        """

        MOVING_AVERAGE = "moving_average", "Moving average"
        FIFO = "fifo", "First in, first out (FIFO)"
        LIFO = "lifo", "Last in, first out (LIFO)"

    shop_name = models.CharField(max_length=120, default="نقطة البيع")
    # The shop's vertical, chosen in the first-run setup wizard. Empty until
    # then; drives the preset defaults but every setting stays editable after.
    shop_type = models.CharField(max_length=32, blank=True, default="")
    # Display currency. One currency per shop for now; ``currency_symbol`` is
    # what the apps and printed documents render next to amounts (the setup
    # wizard hints at fuller multi-currency support as a future step).
    currency_code = models.CharField(max_length=8, default="LYD")
    currency_symbol = models.CharField(max_length=8, default="د.ل")
    receipt_header = models.CharField(max_length=240, blank=True)
    receipt_footer = models.CharField(max_length=240, blank=True)
    enable_online_invoices = models.BooleanField(default=False)
    # Operations modes: which job workflows this shop uses. All off by default
    # so a pure retail shop never sees the feature.
    enable_repair_operations = models.BooleanField(default=False)
    enable_production_operations = models.BooleanField(default=False)
    enable_kitchen_operations = models.BooleanField(default=False)
    # Kitchen lane. When on (the default), a paid POS order's kitchen job is
    # finalized immediately — recipe ingredients leave stock at the sale and the
    # job is marked complete — so cooks just read the printed chit and never
    # touch a screen. Turn it off to keep the staged received→preparing→served
    # flow (the foundation for a future kitchen display / KDS).
    kitchen_auto_complete = models.BooleanField(default=True)
    # Public job tracking page (relay-gated), like online invoices.
    enable_job_tracking = models.BooleanField(default=False)
    require_opening_cash = models.BooleanField(default=True)
    auto_print_receipts = models.BooleanField(default=False)
    # Auto-print floor: how big a sale has to be before it prints by itself.
    # A shop that sells single cheap items all day does not want a slip for one
    # loaf of bread, but does want one for the weekly shop. A sale prints when
    # it clears EITHER floor — enough lines OR enough money — so they are
    # alternatives, not conditions to satisfy together. Null (or 0) on both,
    # the default, means every sale prints, which is what auto-print meant
    # before these existed. Nothing here stops a cashier printing by hand.
    auto_print_min_line_count = models.PositiveIntegerField(
        blank=True,
        null=True,
    )
    auto_print_min_total = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(0)],
    )
    auto_print_kitchen_tickets = models.BooleanField(default=False)
    allow_overselling = models.BooleanField(default=False)
    prevent_selling_at_loss = models.BooleanField(default=True)
    low_stock_threshold = models.PositiveIntegerField(default=5)
    # How stock is costed when it was bought at several prices. Moving average
    # is the default because it is what the shops we run today were already
    # getting in spirit — one blended cost per item — and because it is the
    # method whose numbers move least when a purchase price jumps. Chosen in the
    # first-run wizard; changing it later is guarded, not forbidden.
    inventory_valuation_method = models.CharField(
        max_length=20,
        choices=ValuationMethod.choices,
        default=ValuationMethod.MOVING_AVERAGE,
    )
    # The month the shop's financial year opens on. January is the calendar
    # year and the default; a shop whose year ends in June sets 7 and gets its
    # own year from the "this year" / "last year" report presets instead of
    # having to pick 1 July and 30 June by hand every time. Reporting only —
    # nothing in the trading path reads it.
    fiscal_year_start_month = models.PositiveSmallIntegerField(
        default=1,
        validators=[MinValueValidator(1), MaxValueValidator(12)],
    )
    # Money events dated on or before this day are closed: the period has been
    # reported and must not move underneath the report. Blank until an owner
    # closes their first period. Enforced by ``apps.core.period_lock``; holders
    # of ``reports.override_period_lock`` can still post, and every override is
    # recorded as an audit event.
    books_locked_through = models.DateField(blank=True, null=True)
    # The day of the month the closed month is snapshotted on. 0 turns it off.
    # The snapshot matters more than the notification: it stores last month's
    # figures the moment the month ends, so "are September's numbers still what
    # I reported?" has a baseline nobody had to remember to create.
    month_end_snapshot_day = models.PositiveSmallIntegerField(
        default=1,
        validators=[MaxValueValidator(28)],
    )
    # Where the month-end headline is sent. Blank means snapshot only — the
    # figures are stored and nothing is messaged.
    month_end_report_phone = models.CharField(max_length=32, blank=True)
    # The POS pops a confirmation dialog when a cart line's quantity exceeds the
    # available stock. Shops that routinely sell into negative stock (with
    # ``allow_overselling`` on) can switch this off so checkout completes without
    # the per-sale prompt. On by default, so the warning is opt-out.
    warn_low_stock_before_sale = models.BooleanField(default=True)
    # Stock-count variance review thresholds. A counted line is flagged for
    # review only when the gap is at least ``min_units`` AND at least
    # ``percent`` of the expected quantity (see apps.inventory.services).
    stock_count_variance_min_units = models.DecimalField(
        max_digits=12,
        decimal_places=3,
        default=1,
        validators=[MinValueValidator(0)],
    )
    stock_count_variance_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=10,
        validators=[MinValueValidator(0)],
    )
    cashier_return_window_hours = models.PositiveIntegerField(default=42)
    enable_cash_payments = models.BooleanField(default=True)
    enable_card_payments = models.BooleanField(default=True)
    enable_transfer_payments = models.BooleanField(default=True)
    require_card_payment_receipt = models.BooleanField(default=False)
    trusted_card_terminal_ids = models.JSONField(default=list, blank=True)
    card_commission_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=1,
        validators=[MinValueValidator(0)],
    )
    transfer_commission_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(0)],
    )
    # When on, a quotation (عرض سعر) or debt/credit invoice (آجل) must be tied to
    # a customer account so the receivable is collectable. Owners can disable it
    # for walk-in flexibility. Standard cash-and-carry sales are never gated.
    require_customer_for_credit = models.BooleanField(default=True)
    # Master switch for credit ceilings. OFF by default, deliberately: shops
    # already trading on آجل have been extending credit on judgement and a
    # relationship, and a limit that switched itself on during an update would
    # start refusing their regulars at the till with no warning. An owner turns
    # this on when they want the rule, and nothing below is consulted until
    # they do.
    # ``db_default`` as well as ``default``: Django backfills a new column
    # with the Python default and then drops the database default, and the
    # *older* backend still serving during a live update writes an INSERT
    # that names no such column. See DOCUMENT_LIFECYCLE_PLAN.md §11.
    enforce_customer_credit_limits = models.BooleanField(
        default=False, db_default=False
    )
    # The credit ceiling every customer inherits unless their own record says
    # otherwise (آجل). Null = no limit, which is what every shop had before this
    # setting existed and therefore what an upgrade must keep. 0 is the
    # opposite and a legitimate choice: nobody buys on credit unless a specific
    # customer is exempted or given their own number. The gate is applied
    # wherever credit is issued — see apps.customers.receivables.assess_credit.
    default_customer_credit_limit = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(0)],
    )
    # When a credit (آجل) invoice falls due, for every customer who does not
    # carry their own terms. Zero days on NET_DAYS — due the day it is issued —
    # is the deliberate default: it is what an invoice with no due date already
    # means to the reminder sweep and the aging report, so an upgrade changes
    # nothing until an owner sets a term. Resolved through
    # ``apps.customers.payment_terms.resolve_payment_terms``, never read raw.
    default_payment_terms_days = models.PositiveIntegerField(
        default=0,
        db_default=0,
        validators=[MaxValueValidator(MAX_CREDIT_DAYS)],
    )
    default_payment_terms_basis = models.CharField(
        max_length=16,
        choices=PaymentTermsBasis.choices,
        default=PaymentTermsBasis.NET_DAYS,
        db_default=PaymentTermsBasis.NET_DAYS,
    )
    # Lets cashiers look up customers — to attach one to an آجل/quote sale and to
    # collect a customer's debt via the focused collect-debt flow. They still
    # can't browse other cashiers' invoices or edit customer records. Off =
    # customer lookup + debt collection stay manager/accountant only.
    allow_cashier_customer_access = models.BooleanField(default=True)
    # Per-purchase ceiling for POS cash purchases (drawer-paid POs created from
    # the sell screen by holders of purchasing.add_pos_cash_purchase). Applies to
    # every user of that flow — bigger buys belong in the purchasing screen.
    # Null or 0 = no cap (0 would otherwise block the flow entirely).
    pos_cash_purchase_limit = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(0)],
    )
    # Purchase suggestions: the purchasing screen offers the products and
    # quantities this shop habitually buys from the chosen supplier (see
    # apps.purchasing.suggestions). On by default because it is additive — every
    # suggestion is a chip that costs one tap to take and none to ignore — and
    # because a shop with no purchase history simply never sees one. Off means
    # the surfaces disappear AND the client stops asking for them.
    enable_purchase_suggestions = models.BooleanField(default=True)
    # --- Surveillance (DVR/NVR cameras) -----------------------------------
    # Master switch for the camera wall and invoice playback. Off until a
    # recorder actually connects, at which point the backend turns it on (see
    # apps.surveillance.services.enable_surveillance_feature) — a shop that has
    # just wired up its DVR and then finds no cameras anywhere concludes the
    # integration is broken. A manager can turn it off again, and nothing turns
    # it back on after that.
    #
    # ``db_default`` as well as ``default``: an older backend still serving
    # during a live update writes INSERTs that name no such column.
    enable_surveillance = models.BooleanField(default=False, db_default=False)
    # How much footage either side of a sale the invoice player opens on. The
    # defaults put the customer walking up to the counter at the start and the
    # goods bagged by the end; a shop with a slow till lengthens them.
    # ``db_default`` for the same reason as the flag above, which these two were
    # added alongside and which got it: without one, Django drops the database
    # default after backfilling, and an INSERT from the older backend during a
    # live update names no such column and fails NOT NULL.
    surveillance_pre_roll_seconds = models.PositiveSmallIntegerField(
        default=20,
        db_default=20,
        validators=[MaxValueValidator(600)],
    )
    surveillance_post_roll_seconds = models.PositiveSmallIntegerField(
        default=40,
        db_default=40,
        validators=[MaxValueValidator(600)],
    )
    # --- Multi-currency ---------------------------------------------------
    # ``currency_code`` above IS the base currency: the currency every total,
    # balance, report and stored money column in this product is denominated
    # in. It has carried that meaning implicitly since the first migration; the
    # settings below are what finally give it arithmetic consequences.
    #
    # Master switch for the whole feature. Off means the product behaves exactly
    # as it did before multi-currency existed — no rate lookups, no dual price
    # display, no staleness banner — so a shop with no foreign exposure never
    # pays the complexity.
    fx_enabled = models.BooleanField(default=False)
    # How this shop actually pays for foreign goods. BOTH values are
    # parallel-market rates: ``bank`` is the parallel rate for settling by
    # transfer / letter of credit / certificate rather than in physical cash,
    # NOT the official CBL rate. Getting this wrong costs the shop the
    # cash-to-transfer spread on every import, silently, so it is asked in setup
    # rather than defaulted and forgotten. See ``apps.fx.currencies``.
    fx_instrument = models.CharField(
        max_length=8,
        choices=[
            (fx_ref.INSTRUMENT_CASH, fx_ref.INSTRUMENT_LABELS_EN[fx_ref.INSTRUMENT_CASH]),
            (fx_ref.INSTRUMENT_BANK, fx_ref.INSTRUMENT_LABELS_EN[fx_ref.INSTRUMENT_BANK]),
        ],
        default=fx_ref.INSTRUMENT_CASH,
    )
    # Which bank's series to price off, when settling through a bank. Blank
    # falls back to the generic bank rate, and the resolver reports which series
    # it actually used rather than quietly substituting one.
    fx_bank_code = models.CharField(max_length=32, blank=True, default="")
    # How old a rate may be before the app says so. A stale rate is never an
    # error — it is the last thing we knew, and a sale must never wait on the
    # network — but it must be visible, because pricing off a nine-day-old
    # parallel rate is a decision, not an accident.
    fx_rate_staleness_hours = models.PositiveIntegerField(default=24)
    # Ignore the relay feed entirely and use only rates the shop types. For
    # owners who negotiate their own rate with a specific changer and do not
    # want a published number moving their prices.
    fx_manual_only = models.BooleanField(default=False)

    objects = ShopSettingsQuerySet.as_manager()

    class Meta:
        verbose_name = "shop settings"
        verbose_name_plural = "shop settings"

    def __str__(self):
        return self.shop_name

    @classmethod
    def load(cls):
        # Hot: called by checkout, catalog, discounts — often several times per
        # request. Served from Redis (fail-open); invalidated by post_save (see
        # signals.py) and by the queryset ``update()`` override above.
        from apps.core import caching

        return caching.get_shop_settings(
            lambda: cls.objects.get_or_create(pk=1)[0]
        )

    def payment_method_enabled(self, method: str) -> bool:
        return {
            "cash": self.enable_cash_payments,
            "card": self.enable_card_payments,
            "transfer": self.enable_transfer_payments,
        }.get(method, False)

    def payment_commission_percent(self, method: str):
        return {
            "card": self.card_commission_percent,
            "transfer": self.transfer_commission_percent,
        }.get(method, 0)

    @property
    def has_auto_print_floor(self) -> bool:
        """Whether auto-print is limited to sales of a certain size at all."""
        return bool(self.auto_print_min_line_count) or bool(
            self.auto_print_min_total
        )

    def sale_clears_auto_print_floor(self, *, line_count, total) -> bool:
        """Whether a sale of this shape is big enough to print by itself.

        The one statement of the rule: whichever floor the shop set, clearing
        *either* of them is enough. Both the server's print queue and the till's
        own local printing ask this same question, so a shop never sees one of
        them print a sale the other would have skipped.

        A floor of 0 reads as "no floor", the same as leaving it empty — a shop
        clearing the box should not accidentally mean "every sale qualifies on
        line count", which is what ``line_count >= 0`` would say.
        """
        min_lines = self.auto_print_min_line_count or 0
        min_total = Decimal(self.auto_print_min_total or 0)
        if min_lines <= 0 and min_total <= 0:
            return True
        if min_lines > 0 and (line_count or 0) >= min_lines:
            return True
        return min_total > 0 and Decimal(str(total or 0)) >= min_total

    def apply_shop_type_preset(self, shop_type: str):
        """Flip the feature defaults for a shop vertical, then record the type.

        Presets are non-destructive defaults — every field stays editable in
        Settings afterwards; the wizard simply gives a sensible starting point.
        """
        for field, value in SHOP_TYPE_PRESETS.get(shop_type, {}).items():
            setattr(self, field, value)
        self.shop_type = shop_type


# Per-vertical default toggles applied by the first-run setup wizard. Only the
# fields that differ from a plain retail shop are listed; everything else keeps
# the model default. All of these remain editable in Settings afterwards.
SHOP_TYPE_PRESETS = {
    ShopSettings.ShopType.GENERAL: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "enable_production_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
    },
    ShopSettings.ShopType.RESTAURANT: {
        "enable_kitchen_operations": True,
        "auto_print_kitchen_tickets": True,
        "kitchen_auto_complete": True,
        "enable_repair_operations": False,
        "enable_production_operations": False,
    },
    ShopSettings.ShopType.GROCERY: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
        "low_stock_threshold": 10,
    },
    ShopSettings.ShopType.PHARMACY: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
    },
    ShopSettings.ShopType.PHONE_REPAIR: {
        "enable_repair_operations": True,
        "enable_job_tracking": True,
        "enable_kitchen_operations": False,
    },
    # A workshop is a repair shop whose items are cars: same job engine, same
    # settlement gate, different identity fields at intake (the client picks
    # "vehicle" by default from this shop type). Job tracking is on because a
    # car in for two days is the case customers phone about.
    ShopSettings.ShopType.CAR_WORKSHOP: {
        "enable_repair_operations": True,
        "enable_job_tracking": True,
        "enable_kitchen_operations": False,
        "enable_production_operations": False,
    },
    ShopSettings.ShopType.BAKERY: {
        "enable_kitchen_operations": True,
        "enable_production_operations": True,
        "auto_print_kitchen_tickets": False,
    },
    ShopSettings.ShopType.RETAIL: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
    },
}


class SystemBackupSchedule(TimeStampedModel):
    enabled = models.BooleanField(default=False)
    destination_path = models.CharField(max_length=1024, blank=True)
    scheduled_time = models.TimeField(default=time(hour=2, minute=0))
    retention_count = models.PositiveSmallIntegerField(
        default=7,
        validators=[MinValueValidator(1)],
    )
    last_scheduled_backup_date = models.DateField(blank=True, null=True)

    class Meta:
        verbose_name = "system backup schedule"
        verbose_name_plural = "system backup schedules"

    def __str__(self):
        if not self.enabled:
            return "System backup schedule disabled"
        return f"System backup schedule at {self.scheduled_time}"

    @classmethod
    def load(cls):
        schedule, _ = cls.objects.get_or_create(
            pk=1,
            defaults={
                "retention_count": django_settings.POINTY_BACKUP_RETENTION_COUNT,
            },
        )
        return schedule


class SystemMaintenanceJob(TimeStampedModel):
    class Operation(models.TextChoices):
        BACKUP = "backup", "Backup"
        RESTORE = "restore", "Restore"

    class Status(models.TextChoices):
        QUEUED = "queued", "Queued"
        RUNNING = "running", "Running"
        SUCCEEDED = "succeeded", "Succeeded"
        FAILED = "failed", "Failed"

    operation = models.CharField(max_length=16, choices=Operation.choices)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.QUEUED,
        db_index=True,
    )
    progress_percent = models.PositiveSmallIntegerField(
        default=0,
        validators=[MaxValueValidator(100)],
    )
    progress_message = models.CharField(max_length=240, blank=True)
    destination_path = models.CharField(max_length=1024, blank=True)
    backup_file_name = models.CharField(max_length=255, blank=True)
    backup_file_path = models.CharField(max_length=1024, blank=True)
    archive_size_bytes = models.PositiveBigIntegerField(default=0)
    error_message = models.TextField(blank=True)
    metadata = models.JSONField(default=dict, blank=True)
    initiated_by_user_id = models.PositiveBigIntegerField(blank=True, null=True)
    initiated_by_username = models.CharField(max_length=150, blank=True)
    started_at = models.DateTimeField(blank=True, null=True)
    completed_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["operation", "status", "-created_at"]),
            models.Index(fields=["status", "-created_at"]),
        ]

    def __str__(self):
        return f"{self.operation} {self.status} #{self.pk}"

    @property
    def is_active(self):
        return self.status in {self.Status.QUEUED, self.Status.RUNNING}

    def mark_running(self, message=""):
        self.status = self.Status.RUNNING
        self.started_at = self.started_at or timezone.now()
        if message:
            self.progress_message = message
        self.save(update_fields=["status", "started_at", "progress_message", "updated_at"])

    def update_progress(self, percent, message=""):
        self.progress_percent = max(0, min(100, int(percent)))
        if message:
            self.progress_message = message
        self.save(update_fields=["progress_percent", "progress_message", "updated_at"])

    def mark_succeeded(self, message=""):
        self.status = self.Status.SUCCEEDED
        self.progress_percent = 100
        self.completed_at = timezone.now()
        if message:
            self.progress_message = message
        self.save(
            update_fields=[
                "status",
                "progress_percent",
                "progress_message",
                "completed_at",
                "updated_at",
            ]
        )

    def mark_failed(self, error_message):
        self.status = self.Status.FAILED
        self.error_message = str(error_message)
        self.completed_at = timezone.now()
        if not self.progress_message:
            self.progress_message = "فشلت العملية."
        self.save(
            update_fields=[
                "status",
                "error_message",
                "progress_message",
                "completed_at",
                "updated_at",
            ]
        )


class RelayInstallation(TimeStampedModel):
    installation_id = models.CharField(max_length=80, unique=True)
    shop_name = models.CharField(max_length=120, blank=True)
    relay_public_api_url = models.URLField(max_length=500)
    relay_connector_address = models.CharField(max_length=255, blank=True)
    connector_token = models.TextField()
    access_token = models.TextField()
    relay_enabled = models.BooleanField(default=False)
    subscription_active = models.BooleanField(default=False)
    ai_enabled = models.BooleanField(default=False)
    subscription_ends_at = models.DateTimeField(null=True, blank=True)
    last_synced_at = models.DateTimeField(null=True, blank=True)
    last_pairing_issued_at = models.DateTimeField(null=True, blank=True)
    connector_last_seen_at = models.DateTimeField(null=True, blank=True)
    connector_version = models.CharField(max_length=80, blank=True)

    class Meta:
        verbose_name = "relay installation"
        verbose_name_plural = "relay installations"

    def __str__(self):
        return self.installation_id

    @classmethod
    def load(cls):
        # Redis-cached like ShopSettings: /me, discovery, and every AI request
        # load this row. Signal-invalidated (signals.py); TTL is the backstop.
        from apps.core import caching

        return caching.get_relay_installation(
            lambda: cls.objects.order_by("created_at").first()
        )

    @property
    def remote_access_supported(self):
        if not self.relay_enabled or not self.subscription_active:
            return False
        if self.subscription_ends_at is None:
            return True
        return timezone.now() < self.subscription_ends_at


class RelayConnectorSetupToken(TimeStampedModel):
    token_hash = models.CharField(max_length=96, unique=True)
    expires_at = models.DateTimeField(null=True, blank=True)
    consumed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = "relay connector setup token"
        verbose_name_plural = "relay connector setup tokens"

    @property
    def is_consumed(self):
        return self.consumed_at is not None

    @property
    def is_expired(self):
        return self.expires_at is not None and timezone.now() >= self.expires_at
