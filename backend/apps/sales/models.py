from decimal import Decimal
import secrets

from django.conf import settings
from django.contrib.contenttypes.fields import GenericRelation
from django.core.validators import MinValueValidator
from django.db import models, transaction
from django.db.models import Prefetch, Q, Sum
from django.utils import timezone

from apps.catalog.models import ProductVariant, VariantOptionValue
from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin
from apps.customers.models import Customer


class RegisterSession(TimeStampedModel):
    class Status(models.TextChoices):
        OPEN = "open", "Open"
        CLOSED = "closed", "Closed"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="register_sessions",
        blank=True,
        null=True,
    )
    owner_key = models.CharField(max_length=64, db_index=True)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    opening_cash = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    closing_cash = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    count_025 = models.PositiveIntegerField(default=0)
    count_050 = models.PositiveIntegerField(default=0)
    count_075 = models.PositiveIntegerField(default=0)
    count_100 = models.PositiveIntegerField(default=0)
    opened_at = models.DateTimeField(auto_now_add=True)
    closed_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["owner_key"],
                condition=Q(status="open"),
                name="unique_open_register_session_per_owner",
            )
        ]

    def __str__(self) -> str:
        return f"{self.owner_key} {self.status} register session"

    @classmethod
    def open_for(cls, user):
        """The user's currently open register session, if any. Shared by every
        drawer-linked flow (expense pay-outs, POS cash purchases)."""
        if user is None or not getattr(user, "is_authenticated", False):
            return None
        return (
            cls.objects.filter(
                owner_key=f"user:{user.pk}",
                status=cls.Status.OPEN,
            )
            .order_by("-created_at")
            .first()
        )

    @property
    def session_number(self) -> str:
        if self.pk is None:
            return "RS"
        return f"RS-{self.pk}"

    @property
    def owner_display_name(self) -> str:
        """Who opened the drawer, spelled out — the till accountability line.

        Falls back to the immutable ``owner_key`` when the account was since
        deleted, so a sale never loses its attribution just because someone
        left the shop.
        """
        owner = self.owner
        if owner is None:
            return self.owner_key
        return owner.get_full_name().strip() or owner.username

    @property
    def owner_short_name(self) -> str:
        """The cashier's first name — what a 58 mm receipt has room for.

        Empty when the account is gone, unlike ``owner_display_name``: this one
        is printed on a slip a customer walks out with, and "user:5" is a worse
        answer there than no line at all. The internal record keeps the key.
        """
        owner = self.owner
        if owner is None:
            return ""
        return owner.first_name.strip() or owner.username

    # The four aggregates below are each read directly by the reconciliation
    # payloads AND re-read by the composites (``expected_cash`` reads all four;
    # ``cash_variance`` re-reads ``expected_cash``; ``has_cash_variance`` re-reads
    # ``cash_variance``), so a single serialized session costs 16 queries. When
    # a whole page of sessions is about to be rendered,
    # ``prime_register_session_cash_totals`` fills the ``_<field>`` caches these
    # properties read first. The arithmetic stays here — only the *fetching* is
    # batched — so a primed session and a cold one can never disagree.

    @property
    def cash_sales_total(self) -> Decimal:
        primed = getattr(self, "_cash_sales_total", None)
        if primed is not None:
            return primed

        from apps.payments.models import Payment

        # Attribute cash to the session that COLLECTED it (the payment's own
        # register_session), not the session that issued the order. Under accrual
        # a credit (debt) order stays OPEN while still collecting a cash
        # down-payment, and a debt may be settled in a later shift — so we no
        # longer gate on order status.
        total = Payment.objects.filter(
            register_session=self,
            method=Payment.Method.CASH,
            amount__gt=0,
        ).aggregate(total=Sum("amount"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def cash_refund_total(self) -> Decimal:
        primed = getattr(self, "_cash_refund_total", None)
        if primed is not None:
            return primed
        total = self.order_adjustments.aggregate(
            total=Sum("cash_amount"),
        )["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def pay_in_total(self) -> Decimal:
        primed = getattr(self, "_pay_in_total", None)
        if primed is not None:
            return primed
        return self._cash_movement_total(RegisterCashMovement.MovementType.PAY_IN)

    @property
    def pay_out_total(self) -> Decimal:
        primed = getattr(self, "_pay_out_total", None)
        if primed is not None:
            return primed
        return self._cash_movement_total(RegisterCashMovement.MovementType.PAY_OUT)

    @property
    def expected_cash(self) -> Decimal:
        total = self.opening_cash + self.cash_sales_total + self.pay_in_total
        return (total - self.pay_out_total - self.cash_refund_total).quantize(
            Decimal("0.01")
        )

    @property
    def denomination_total(self) -> Decimal:
        total = (
            Decimal("0.25") * self.count_025
            + Decimal("0.50") * self.count_050
            + Decimal("0.75") * self.count_075
            + Decimal("1.00") * self.count_100
        )
        return total.quantize(Decimal("0.01"))

    @property
    def cash_variance(self) -> Decimal | None:
        if self.closing_cash is None:
            return None
        return (self.closing_cash - self.expected_cash).quantize(Decimal("0.01"))

    @property
    def has_cash_variance(self) -> bool:
        return self.cash_variance not in (None, Decimal("0.00"))

    def _cash_movement_total(self, movement_type) -> Decimal:
        total = self.cash_movements.filter(movement_type=movement_type).aggregate(
            total=Sum("amount"),
        )["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))


class RegisterCashMovement(TimeStampedModel):
    class MovementType(models.TextChoices):
        PAY_IN = "pay_in", "Pay in"
        PAY_OUT = "pay_out", "Pay out"

    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="cash_movements",
    )
    movement_type = models.CharField(max_length=16, choices=MovementType.choices)
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    reason = models.TextField()
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="register_cash_movements",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.get_movement_type_display()} {self.amount} for {self.register_session}"


class OrderQuerySet(DocumentQuerySetMixin, models.QuerySet):
    """Sale-type/status aware filters for sales orders.

    Quotations never count as sales; credit (debt) invoices count from the
    moment they are issued (accrual); standard orders count once paid.
    """

    def committed_sales(self):
        """Orders whose revenue is recognized: standard orders once paid and
        credit invoices from issue. Excludes quotations and voids."""
        return self.filter(
            Q(sale_type=Order.SaleType.STANDARD, status=Order.Status.PAID)
            | Q(
                sale_type=Order.SaleType.CREDIT,
                status__in=(Order.Status.OPEN, Order.Status.PAID),
            )
        )

    def transactional(self):
        """Recognized sales plus their voids — the basis for sales/profit
        aggregates that net refunds out of a paid+void gross. Always excludes
        quotations (a voided/converted quotation is not a transaction)."""
        return self.exclude(sale_type=Order.SaleType.QUOTATION).filter(
            Q(status__in=(Order.Status.PAID, Order.Status.VOID))
            | Q(sale_type=Order.SaleType.CREDIT, status=Order.Status.OPEN)
        )

    def open_credit(self):
        """Credit (debt) invoices that still carry a balance."""
        return self.filter(
            sale_type=Order.SaleType.CREDIT, status=Order.Status.OPEN
        )

    def due_on_or_before(self, when):
        """Open credit whose due date has arrived — the collectable set.

        A null due date counts as due: an invoice issued with no terms recorded
        is an open tab, payable now. That is how the debt sweep has always read
        it, and the aging report's invoice-date fallback says the same thing.
        """
        return self.open_credit().filter(
            Q(due_date__isnull=True) | Q(due_date__lte=when)
        )

    def overdue(self, when=None):
        """Open credit past its recorded due date.

        Narrower than :meth:`due_on_or_before` by exactly the invoices with no
        due date: "due now" and "late" are different claims, and only one of
        them should colour a screen red.

        Derived, never stored. ERPNext keeps an ``Overdue`` status on the
        invoice and a daily scheduled job to write it
        (``accounts_controller.update_invoice_status``); that is a second source
        of truth which is wrong between midnight and whenever the job runs, and
        this codebase has paid for stored-versus-derived drift before. The
        comparison is indexed — see ``sales_order_credit_due_idx``.
        """
        if when is None:
            from apps.core.timeutils import business_local_date

            when = business_local_date()
        return self.open_credit().filter(due_date__isnull=False, due_date__lt=when)

    def quotations(self):
        return self.filter(sale_type=Order.SaleType.QUOTATION)

    def with_list_serializer_relations(self):
        """Load everything ``OrderListSerializer`` reads, in a fixed query count.

        The row serializers (the invoices list and the register-session strip)
        show a line COUNT plus totals/profit and the returnable flag, never the
        line items — so ``lines`` is prefetched *light*, without the heavy
        variant/product/option trees that ``with_serializer_relations`` adds.
        Everything else the rows read is here, and every one of these costs a
        query **per row** when a caller hand-rolls a shorter list instead:
        ``sales_channel_name``/``_slug`` traverse the FK,
        ``can_void``/``can_return`` read ``adjustment_lines`` per line,
        ``applied_discounts``/``exchanges`` are a query each per order, and the
        lifecycle's ``cancelled_by`` is a query per *voided* order — a page of
        live sales looks flat and a page of voided ones does not.
        """
        return self.with_lifecycle_relations().select_related(
            "customer",
            "register_session",
            # ``cashier_name`` reads the session's owner; without this join it
            # is one query per row on a page of sales rung up by more than one
            # person — invisible on a till's own shift, obvious on the invoices
            # list an owner actually scrolls.
            "register_session__owner",
            "sales_channel",
        ).defer(
            # Only the three name fields are ever read off the joined cashier
            # (``RegisterSession.owner_display_name``/``owner_short_name``).
            # Without this the list drags a password hash and eight unrelated
            # auth columns across for every row on the page. Deferring a field
            # something later decides to read would cost a query per row, so
            # keep this list to columns no serializer touches.
            "register_session__owner__password",
            "register_session__owner__last_login",
            "register_session__owner__is_superuser",
            "register_session__owner__is_staff",
            "register_session__owner__is_active",
            "register_session__owner__email",
            "register_session__owner__date_joined",
        ).prefetch_related(
            "lines__adjustment_lines",
            "payments",
            "applied_discounts",
            "exchanges__replacement_order",
            "exchanges__created_by",
        )

    def with_serializer_relations(self):
        """Load everything ``OrderSerializer`` reads, in a fixed query count.

        This lives on the queryset rather than inline in one viewset because
        several endpoints serialize whole orders (the sales list/detail and the
        customer's invoices tab), and a caller that hand-rolls a shorter prefetch
        list pays for it per row without any visible sign: ``variant.display_name``
        falls back to a query per line when ``option_values`` is missing,
        ``can_void``/``can_return`` read ``adjustment_lines`` per line, and
        ``applied_discounts``/``exchanges`` cost a query per order. Extend this
        method — not a caller's own list — when the serializer grows a field.
        """
        return self.with_list_serializer_relations().prefetch_related(
            "lines__variant__product",
            Prefetch(
                "lines__variant__option_values",
                queryset=VariantOptionValue.objects.select_related("option"),
            ),
        )


class Order(DocumentMixin, TimeStampedModel):
    class Status(models.TextChoices):
        """Where the money and the goods have got to — not whether the document
        is live.

        This field carried both meanings until the lifecycle arrived, and the
        overlap was load-bearing: ``open`` means "still being rung up" for a
        standard sale and "issued, delivered, unpaid" for a credit invoice,
        which is why ``recognized_sale_q`` has to exist and why forty-one call
        sites have to know about it. ``doc_status`` carries the first meaning
        now; this is derived from payments and returns by
        ``apps.sales.documents.progress_status`` and written from nowhere else,
        so every existing query keeps working while the ambiguity stops being
        the only thing holding the reports together.
        """

        OPEN = "open", "Open"
        PAID = "paid", "Paid"
        VOID = "void", "Void"

    class SaleType(models.TextChoices):
        # A normal cash-and-carry sale, paid in full at checkout (default).
        STANDARD = "standard", "Standard"
        # A price offer (فاتورة عرض): not a sale, optionally reserves stock,
        # convertible in place into a real invoice.
        QUOTATION = "quotation", "Quotation"
        # A debt/credit invoice (آجل): a real sale issued unpaid or partly paid;
        # stock leaves and revenue is recognized at issue.
        CREDIT = "credit", "Credit"

    objects = OrderQuerySet.as_manager()

    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="orders",
        blank=True,
        null=True,
    )
    # Stamped by the backend from the request's credentials (see
    # apps.channels.services.resolve_sales_channel) — never from client input.
    sales_channel = models.ForeignKey(
        "channels.SalesChannel",
        on_delete=models.PROTECT,
        related_name="orders",
        blank=True,
        null=True,
    )
    customer = models.ForeignKey(
        Customer,
        on_delete=models.SET_NULL,
        related_name="orders",
        blank=True,
        null=True,
    )
    receipt_number = models.CharField(max_length=32, unique=True, blank=True)
    public_token = models.CharField(
        max_length=64,
        unique=True,
        blank=True,
        null=True,
    )
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    # No per-field index: the (sale_type, status, -created_at) composite below
    # already serves sale_type-leading lookups (quotations / outstanding credit).
    sale_type = models.CharField(
        max_length=16,
        choices=SaleType.choices,
        default=SaleType.STANDARD,
    )
    # How long a quotation's offer — and any stock reservation behind it — stays
    # good. Null = no deadline. This carried a credit invoice's due date too
    # until ``due_date`` below took that over: one column meaning "the offer
    # lapses" and "the money is owed" made every reader guess which sale type it
    # was looking at, and the lapse sweep and the debt sweep were reading the
    # same column for opposite purposes.
    valid_until = models.DateField(blank=True, null=True)
    # When a credit (آجل) invoice is to be settled. Meaningful only for
    # ``SaleType.CREDIT`` — a cash sale is paid at the counter and never grows
    # one, which is what keeps checkout untouched by all of this (ERPNext does
    # the same, returning early from its payment-schedule pass for POS
    # invoices). Null means no terms were recorded, which every reader treats as
    # due now: that is the behaviour every credit invoice already had.
    #
    # Proposed from the customer's terms at issue
    # (``apps.customers.payment_terms.resolve_due_date``) and overridable by
    # whoever rings the sale up.
    due_date = models.DateField(blank=True, null=True)
    # Quotation-only: whether the quoted quantities are actively held
    # (StockReservation rows + StockItem.quantity_committed) until ``valid_until``.
    reserves_stock = models.BooleanField(default=False)
    # When a quotation is accepted it is converted in place into a real sale;
    # this links the (now VOID) quotation to the order that superseded it.
    converted_to = models.ForeignKey(
        "self",
        on_delete=models.SET_NULL,
        related_name="converted_from",
        blank=True,
        null=True,
    )
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    # Snapshot of the special-day keys (apps.holidays) active on the shop-local
    # date of the sale — an immutable feature signal for forecasting that must
    # survive later edits to the holiday calendar.
    special_day_keys = models.JSONField(default=list, blank=True)
    # Reverse accessor for the discounts applied to this order document so the
    # API can prefetch them in a single query instead of one lookup per order
    # row when serialising lists of orders.
    applied_discounts = GenericRelation(
        "discounts.AppliedDiscount",
        content_type_field="document_content_type",
        object_id_field="document_object_id",
    )

    class Meta:
        ordering = ["-created_at"]
        # Almost every aggregate filters status IN (paid, void) over a date
        # range; this composite serves those plus the default -created_at listing.
        # The second composite serves the sale-type splits (quotations list,
        # outstanding credit invoices).
        indexes = [
            models.Index(
                fields=["status", "-created_at"],
                name="sales_order_status_created_idx",
            ),
            models.Index(
                fields=["sale_type", "status", "-created_at"],
                name="sales_order_type_status_idx",
            ),
            # The debt-reminder sweep and the aging report both ask the same
            # question — open credit invoices due on or before a date — and the
            # composite above cannot serve it, because ``-created_at`` sits
            # between the equality columns and the range one.
            models.Index(
                fields=["sale_type", "status", "due_date"],
                name="sales_order_credit_due_idx",
            ),
        ]
        permissions = [
            # Lets a trusted cashier look up a single invoice by its receipt
            # number and return/exchange it — without browsing the full invoice
            # list, and overriding the short cashier-window time limit. Granted
            # per-user from the permission catalog; not part of any role default.
            (
                "process_return_lookup",
                "Look up and return/exchange any invoice by receipt number",
            ),
        ]

    def recalculate(self) -> None:
        subtotal = Decimal("0.00")
        discount_total = Decimal("0.00")
        for line in self.lines.select_related("variant", "variant__product"):
            subtotal += line.line_subtotal
            discount_total += line.discount_total
        self.subtotal = subtotal.quantize(Decimal("0.01"))
        self.discount_total = min(
            discount_total.quantize(Decimal("0.01")),
            self.subtotal,
        )
        self.total = (self.subtotal - self.discount_total).quantize(Decimal("0.01"))

    @property
    def total_cost(self):
        total = sum((line.line_cost for line in self.lines.all()), Decimal("0.00"))
        return total.quantize(Decimal("0.01"))

    @property
    def total_profit(self):
        total = sum((line.line_profit for line in self.lines.all()), Decimal("0.00"))
        return total.quantize(Decimal("0.01"))

    @property
    def amount_paid(self):
        # Sum in Python so a prefetched ``payments`` is reused instead of a
        # per-order aggregate when serialising lists of orders. Includes any
        # negative (refund) payments so the balance reflects net cash received.
        total = sum(
            (payment.amount for payment in self.payments.all()),
            Decimal("0.00"),
        )
        return total.quantize(Decimal("0.01"))

    @property
    def raw_balance_due(self):
        return (self.total - self.amount_paid).quantize(Decimal("0.01"))

    @property
    def balance_due(self):
        return max(self.raw_balance_due, Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def is_overdue(self):
        """Past its due date with money still owed.

        Only a credit invoice can be late. A quotation has an expiry, not a
        debt, and a cash sale has neither — reading ``due_date`` without the
        sale-type guard would make any stray value on another type look like an
        unpaid bill.
        """
        from apps.core.timeutils import business_local_date

        return (
            self.sale_type == self.SaleType.CREDIT
            and self.status == self.Status.OPEN
            and self.due_date is not None
            and self.due_date < business_local_date()
            and self.balance_due > Decimal("0.00")
        )

    @property
    def days_overdue(self):
        """How many days late, or 0. Never negative — an invoice due next week
        is not "-7 days overdue", it is simply not overdue."""
        from apps.core.timeutils import business_local_date

        if not self.is_overdue:
            return 0
        return (business_local_date() - self.due_date).days

    @property
    def payment_status(self):
        if self.sale_type == self.SaleType.QUOTATION:
            return "quotation"
        if self.balance_due == Decimal("0.00"):
            return "paid"
        if self.amount_paid > 0:
            return "partial"
        return "unpaid"

    def _follow_progress_on_insert(self):
        """Bridge for the migration window: an order created already paid or
        already void gets the lifecycle that says.

        Only the two unambiguous cases. ``open`` deliberately stays a draft,
        because it is the value that means two things — the transitions decide
        it, and an explicit ``doc_status`` always wins.
        """
        from apps.documents.statuses import DocumentStatus

        if not self._state.adding or self.doc_status != DocumentStatus.DRAFT:
            return
        if self.status == Order.Status.PAID:
            self.doc_status = DocumentStatus.SUBMITTED
        elif self.status == Order.Status.VOID:
            self.doc_status = DocumentStatus.CANCELLED

    def save(self, *args, **kwargs):
        self._follow_progress_on_insert()
        update_fields = kwargs.get("update_fields")
        if not self.public_token:
            self.public_token = self._generate_public_token()
            if update_fields is not None and "public_token" not in update_fields:
                update_fields = [*update_fields, "public_token"]
        if self.receipt_number:
            if update_fields is not None:
                kwargs["update_fields"] = update_fields
            return super().save(*args, **kwargs)

        # The number and the row it belongs to are written as one unit, even
        # when the caller brought no transaction of its own. A number allocated
        # by a write that then fails is exactly the hole this is here to close,
        # and checkout is not the only thing that creates an order.
        with transaction.atomic():
            self.receipt_number = self._next_receipt_number()
            if update_fields is not None and "receipt_number" not in update_fields:
                update_fields = [*update_fields, "receipt_number"]
            if update_fields is not None:
                kwargs["update_fields"] = update_fields
            return super().save(*args, **kwargs)

    def _next_receipt_number(self) -> str:
        """The next number in the shop's receipt series.

        It used to be ``R{date}{self.id}`` — the row's own primary key, which
        meant the receipt series inherited every gap a key is allowed to have.
        In one field week it skipped 155 numbers across five unclean database
        restarts, because PostgreSQL reserves 32 sequence values in WAL at a
        time and discards the unused remainder on recovery. Nobody could
        explain the missing invoices to a shop whose paper ledger is the thing
        it actually trusts. See ``apps.documents.numbering``.

        Taking the number before the insert rather than after it also means one
        write per sale instead of two, and removes the ``system_write`` escape
        the second write needed: an order created already paid used to have its
        own numbering refused as an edit to a submitted document.
        """
        from apps.documents.numbering import (
            SALE_ORDER_SERIES,
            next_document_number,
        )

        # `created_at` is auto_now_add, so it is not set until the insert; this
        # is the same clock it will be stamped from, and the date part of the
        # number is unchanged from when it was read off the saved row.
        issued_at = self.created_at or timezone.now()
        return f"R{issued_at:%Y%m%d}{next_document_number(SALE_ORDER_SERIES):06d}"

    def __str__(self) -> str:
        return self.receipt_number or f"Order {self.pk}"

    @classmethod
    def _generate_public_token(cls) -> str:
        while True:
            token = secrets.token_urlsafe(24)
            if not cls.objects.filter(public_token=token).exists():
                return token


def recognized_sale_q(prefix: str = "") -> Q:
    """``Q`` matching orders whose revenue is recognized (see
    ``OrderQuerySet.committed_sales``). ``prefix`` targets a related accessor,
    e.g. ``recognized_sale_q("orders")`` -> ``orders__status=...`` for use in
    cross-relation filters and ``Count(filter=...)`` annotations."""
    p = f"{prefix}__" if prefix else ""
    return Q(
        **{f"{p}sale_type": Order.SaleType.STANDARD, f"{p}status": Order.Status.PAID}
    ) | Q(
        **{
            f"{p}sale_type": Order.SaleType.CREDIT,
            f"{p}status__in": (Order.Status.OPEN, Order.Status.PAID),
        }
    )


def transactional_sale_q(prefix: str = "") -> Q:
    """``Q`` matching recognized sales plus their voids, always excluding
    quotations. Mirror of ``OrderQuerySet.transactional`` for use across a
    related accessor or inside ``Count(filter=...)`` annotations."""
    p = f"{prefix}__" if prefix else ""
    return ~Q(**{f"{p}sale_type": Order.SaleType.QUOTATION}) & (
        Q(**{f"{p}status__in": (Order.Status.PAID, Order.Status.VOID)})
        | Q(**{f"{p}sale_type": Order.SaleType.CREDIT, f"{p}status": Order.Status.OPEN})
    )


class OrderLine(TimeStampedModel):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="lines")
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="order_lines",
    )
    quantity = models.DecimalField(
        max_digits=10,
        decimal_places=3,
        default=1,
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    # The unit this line was sold in (a UnitOfMeasure.code); blank = the product's
    # base unit. ``unit_factor`` is a snapshot of how many base units one of that
    # unit is worth, so quantity/price/cost stay self-consistent and stock can be
    # reconciled in base units even after the product's units are later edited.
    unit = models.CharField(max_length=32, blank=True, default="")
    unit_factor = models.DecimalField(
        max_digits=18,
        decimal_places=6,
        default=Decimal("1"),
        validators=[MinValueValidator(Decimal("0.000001"))],
    )
    # Free-text kitchen instruction for a single line (e.g. "no onions").
    # Short by design so it never blows out a thermal kitchen chit.
    notes = models.CharField(max_length=255, blank=True, default="")

    class Meta:
        ordering = ["created_at"]

    @property
    def base_quantity(self):
        # Quantity converted into the product's base (stock) unit.
        return (self.quantity * self.unit_factor).quantize(Decimal("0.001"))

    @property
    def line_subtotal(self):
        return (self.unit_price * self.quantity).quantize(Decimal("0.01"))

    @property
    def line_total(self):
        return (self.line_subtotal - self.discount_total).quantize(Decimal("0.01"))

    @property
    def line_cost(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))

    @property
    def line_profit(self):
        return (self.line_total - self.line_cost).quantize(Decimal("0.01"))

    @property
    def returned_quantity(self) -> int:
        # Sum in Python so a prefetched ``adjustment_lines`` is reused instead of
        # firing a per-line aggregate query when serialising lists of orders.
        total = sum((line.quantity for line in self.adjustment_lines.all()), 0)
        return total or 0

    @property
    def returnable_quantity(self) -> int:
        return max(self.quantity - self.returned_quantity, 0)

    @property
    def returned_discount_total(self) -> Decimal:
        total = sum(
            (line.discount_total for line in self.adjustment_lines.all()),
            Decimal("0.00"),
        )
        return total.quantize(Decimal("0.01"))


class OrderLineModifier(TimeStampedModel):
    """A structured modifier chosen for a single order line (e.g. "Oat milk",
    "Extra shot ×2"). The selected option's per-unit price delta is already
    folded into OrderLine.unit_price; these rows carry the breakdown for the
    chit/receipt and are snapshotted so reprints survive catalog edits."""

    order_line = models.ForeignKey(
        OrderLine,
        on_delete=models.CASCADE,
        related_name="modifiers",
    )
    modifier_option = models.ForeignKey(
        "catalog.ModifierOption",
        on_delete=models.SET_NULL,
        related_name="order_line_modifiers",
        blank=True,
        null=True,
    )
    group_name = models.CharField(max_length=160, blank=True)
    option_name = models.CharField(max_length=160, blank=True)
    unit_price_delta = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    quantity = models.PositiveIntegerField(default=1)

    class Meta:
        ordering = ["id"]

    @property
    def line_price_delta(self) -> Decimal:
        return (self.unit_price_delta * self.quantity).quantize(Decimal("0.01"))

    def __str__(self) -> str:
        return f"{self.option_name} ×{self.quantity}"


class OrderAdjustment(TimeStampedModel):
    class AdjustmentType(models.TextChoices):
        VOID = "void", "Void"
        RETURN = "return", "Return"

    order = models.ForeignKey(
        Order,
        on_delete=models.PROTECT,
        related_name="adjustments",
    )
    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="order_adjustments",
    )
    adjustment_type = models.CharField(max_length=16, choices=AdjustmentType.choices)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    refund_method = models.CharField(max_length=16, default="cash")
    # Portion of ``amount`` that actually left the cash drawer. For a
    # single-tender cash refund this equals ``amount``; for a card/transfer
    # refund it is 0; for a split-tender sale it is just the cash share.
    # Register reconciliation, dashboards, reports and fraud metrics read THIS
    # field (not ``refund_method``) so a card refund never wrongly reduces
    # expected cash and a split refund is attributed to the right drawer.
    cash_amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    reason = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="order_adjustments",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.adjustment_type} {self.amount} for {self.order_id}"


class OrderAdjustmentLine(TimeStampedModel):
    adjustment = models.ForeignKey(
        OrderAdjustment,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    order_line = models.ForeignKey(
        OrderLine,
        on_delete=models.PROTECT,
        related_name="adjustment_lines",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="order_adjustment_lines",
    )
    quantity = models.DecimalField(
        max_digits=10,
        decimal_places=3,
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        """What this refund line is worth.

        Rounds the gross to the cent *before* taking the discount off, which is
        both what the refund is actually paid out with
        (``services.line_refund_amount``) and what the sale charged in the first
        place (``OrderLine.line_subtotal`` → ``OrderLine.line_total``).

        Subtracting from an *unrounded* gross instead diverges by a cent
        whenever ``unit_price × quantity`` lands on a half-cent — 0.750 kg at
        5.50 is 4.125, which rounds to 4.12 on its own but carries the extra
        half-cent up through the subtraction — so an itemised return receipt
        stopped adding up to the money that left the drawer, and credited the
        line more than the sale had ever charged for it.
        """
        line_subtotal = (self.unit_price * self.quantity).quantize(Decimal("0.01"))
        return (line_subtotal - self.discount_total).quantize(Decimal("0.01"))


def returned_cost_total(adjustments) -> Decimal:
    """Cost of the goods that came back with ``adjustments`` (voids + returns).

    Every adjustment restocks what it takes back, so the shop keeps the goods
    and their cost. Netting refunds out of profit must therefore subtract only
    the *margin* that was reversed — ``refund_total - returned_cost_total`` —
    otherwise voiding a sale would reduce reported profit by the whole cost of
    goods that never left the shelf.

    ``OrderAdjustmentLine.quantity`` is in the order line's transacted unit,
    which is the unit ``OrderLine.unit_cost`` is snapshotted in, so the two
    multiply directly.
    """
    total = OrderAdjustmentLine.objects.filter(adjustment__in=adjustments).aggregate(
        total=Sum(
            models.F("quantity") * models.F("order_line__unit_cost"),
            output_field=models.DecimalField(max_digits=12, decimal_places=2),
        )
    )["total"]
    return (total or Decimal("0.00")).quantize(Decimal("0.01"))


# Cost of one sold line lives with its revenue and profit siblings below, in
# ``sold_cost_expression`` — the three must share one convention: raw product,
# summed, rounded once at the end. If a sale subtracted a per-line-rounded cost
# while its return added back a raw-summed one, undoing the sale would not
# return profit to where it started. ``returned_cost_total`` above is the other
# half of that pair.


# ---------------------------------------------------------------------------
# Per-product / per-variant rollups, net of what came back
# ---------------------------------------------------------------------------
#
# The shop-wide totals net refunds out (``gross_profit_total`` above), but every
# *ranking* built on top of the same lines used to state the gross sale and stop
# there: sell five, void the sale, and "top products" still credited the product
# with five units, its revenue and its margin. Rankings drive what a shop
# reorders and what it stops stocking, so a voided mis-scan or a returned batch
# quietly promotes goods the shop never actually sold.
#
# The two sides state the *same* arithmetic over the *same* snapshot columns —
# ``OrderAdjustmentLine`` copies the sale line's ``unit_price`` and its share of
# ``discount_total``, and takes cost from ``order_line__unit_cost`` — so a line
# handed back in full cancels its own sale term for term, whatever the figures
# were. That is the conservation law these rollups are chosen to satisfy, and it
# is why both sides are summed raw and rounded once by the caller (the
# convention ``SOLD_COST_EXPRESSION`` and ``returned_cost_total`` already share).
def sold_revenue_expression(prefix=""):
    """Revenue of a sold line, addressable from a parent queryset.

    ``prefix`` is the relation path to the line — ``"lines__"`` when
    aggregating over ``Order``. It exists so a caller that needs line-level
    money one join away reuses *this* arithmetic instead of retyping it: the AI
    tools kept their own copy of exactly this expression, which is how they
    ended up reporting a revenue the reports had already stopped reporting.
    """
    return (
        models.F(f"{prefix}quantity") * models.F(f"{prefix}unit_price")
        - models.F(f"{prefix}discount_total")
    )


def sold_profit_expression(prefix=""):
    """Profit of a sold line — revenue less what the goods cost."""
    return models.F(f"{prefix}quantity") * (
        models.F(f"{prefix}unit_price") - models.F(f"{prefix}unit_cost")
    ) - models.F(f"{prefix}discount_total")


def sold_cost_expression(prefix=""):
    """Cost of a sold line."""
    return models.F(f"{prefix}quantity") * models.F(f"{prefix}unit_cost")


SOLD_REVENUE_EXPRESSION = sold_revenue_expression()
SOLD_PROFIT_EXPRESSION = sold_profit_expression()
SOLD_COST_EXPRESSION = sold_cost_expression()
RETURNED_REVENUE_EXPRESSION = (
    models.F("quantity") * models.F("unit_price") - models.F("discount_total")
)
RETURNED_PROFIT_EXPRESSION = models.F("quantity") * (
    models.F("unit_price") - models.F("order_line__unit_cost")
) - models.F("discount_total")

_ROLLUP_MONEY = models.DecimalField(max_digits=14, decimal_places=2)
_ROLLUP_QTY = models.DecimalField(max_digits=16, decimal_places=3)


def _rollup(queryset, keys, *, quantity_expr, revenue_expr, profit_expr, extra=None):
    rows = queryset.values(*keys).annotate(
        rollup_quantity=Sum(quantity_expr, output_field=_ROLLUP_QTY),
        rollup_revenue=Sum(revenue_expr, output_field=_ROLLUP_MONEY),
        rollup_profit=Sum(profit_expr, output_field=_ROLLUP_MONEY),
        **(extra or {}),
    )
    return {tuple(row[key] for key in keys): row for row in rows}


def net_line_rollups(orders, adjustments, *keys, labels=(), extra=None):
    """Units, revenue and profit per ``keys``, net of everything handed back.

    ``keys`` are field paths that must resolve on **both** ``OrderLine`` and
    ``OrderAdjustmentLine`` — the two share a ``variant``, so anything reached
    through it groups the same way on either side and the halves merge on the
    same tuple. ``labels`` are extra display-only fields carried from the sold
    side (names, SKUs); they never take part in the merge, and ``extra`` are
    further aggregates over the sold side alone — nothing came *back* in a
    variant count — computed inside the same GROUP BY rather than as a query of
    their own.

    Scope mirrors the summary figures exactly: ``orders`` and ``adjustments``
    are the period's own document sets, the same two the report already sums
    into ``net_sales``. A ranking built from a different set of documents than
    the top line it sits under cannot reconcile with it.

    Sums are raw and unrounded — the caller rounds once, so a fully returned
    line contributes exactly nothing rather than a rounding residue.
    """
    keys = tuple(keys)
    sold = _rollup(
        OrderLine.objects.filter(order__in=orders),
        keys + tuple(labels),
        quantity_expr=models.F("quantity"),
        revenue_expr=SOLD_REVENUE_EXPRESSION,
        profit_expr=SOLD_PROFIT_EXPRESSION,
        extra=extra,
    )
    returned = _rollup(
        OrderAdjustmentLine.objects.filter(adjustment__in=adjustments),
        keys,
        quantity_expr=models.F("quantity"),
        revenue_expr=RETURNED_REVENUE_EXPRESSION,
        profit_expr=RETURNED_PROFIT_EXPRESSION,
    )
    rows = []
    for sold_key, row in sold.items():
        back = returned.get(sold_key[: len(keys)])
        quantity = row["rollup_quantity"] or Decimal("0")
        revenue = row["rollup_revenue"] or Decimal("0")
        profit = row["rollup_profit"] or Decimal("0")
        if back is not None:
            quantity -= back["rollup_quantity"] or Decimal("0")
            revenue -= back["rollup_revenue"] or Decimal("0")
            profit -= back["rollup_profit"] or Decimal("0")
        rows.append(
            {
                **{
                    key: row[key]
                    for key in keys + tuple(labels) + tuple(extra or ())
                },
                "quantity": quantity,
                "revenue": revenue,
                "profit": profit,
            }
        )
    return rows


def net_product_rollups(orders, adjustments):
    """One netted row per product sold in the period, ready to rank.

    The dashboard and the reports layer both rank products by revenue and both
    used to build the row themselves; the shared row is what keeps the two
    stating the same number.
    """
    return [
        {
            "product_id": row["variant__product_id"],
            "product_name": row["variant__product__name"],
            "quantity": row["quantity"],
            "revenue": row["revenue"],
            "profit": row["profit"],
            "variant_count": row["variant_count"],
            "sort_name": row["variant__product__name"] or "",
        }
        for row in net_line_rollups(
            orders,
            adjustments,
            "variant__product_id",
            labels=("variant__product__name",),
            extra={"variant_count": models.Count("variant_id", distinct=True)},
        )
    ]


def rank_rollups(rows, *, order_by, limit):
    """Rank netted rollup rows: the ordering figure descending, ties broken by
    the row's ``sort_name`` ascending — the ordering the SQL used to do.

    Ranking has to happen *after* netting rather than before. Netting only ever
    lowers a row, but by different amounts, so the gross top-N is not the netted
    top-N: a product sold 100 and returned in full ranks below one sold 90 and
    kept, and no fixed window of gross candidates is guaranteed to contain the
    answer. The rows this sorts are bounded by the assortment sold in the period
    rather than by the transaction volume — the same trade ``register_summary``
    already makes for its per-category breakdown.

    Shared by the dashboard and the reports layer on purpose: they state the
    same ranking, and two implementations of one answer is how the per-product
    rows came to disagree with the top line in the first place.

    Ranks on the figure the row will *display*, not on the raw sum behind it.
    The sums arrive from the database with whatever precision the engine's
    aggregate carried, so ordering on them would let a difference far below a
    cent decide which of two rows showing the same money comes first — and
    decide it differently on SQLite than on Postgres.
    """
    key = order_by.lstrip("-")
    places = Decimal("0.001") if key == "quantity" else Decimal("0.01")
    return sorted(
        rows,
        key=lambda row: (-Decimal(row[key]).quantize(places), row["sort_name"]),
    )[:limit]


def returned_items_total(adjustments) -> Decimal:
    """Units handed back over ``adjustments`` — the term ``items_sold`` was
    missing. Stated gross, "items sold: 5" sat next to "net sales: 0.00" on the
    very same summary block after a sale was voided.

    Its own aggregate rather than something folded into the caller's: the sold
    term comes off ``OrderLine`` and this one off ``OrderAdjustmentLine``, and
    joining the two would repeat each sale line once per return taken against
    it and count the sale that many times over.
    """
    return (
        OrderAdjustmentLine.objects.filter(adjustment__in=adjustments).aggregate(
            total=Sum("quantity", output_field=_ROLLUP_QTY)
        )["total"]
        or Decimal("0")
    )


def gross_profit_total(*, revenue, sold_cost, refund_total, adjustments) -> Decimal:
    """Gross profit over a period: revenue less the cost of the goods sold, less
    the margin (not the cost) of whatever was handed back.

    ``revenue`` must be the **documents'** revenue — ``Sum(Order.total)``, the
    money the customers were actually charged — and not a re-derivation of it
    from raw line arithmetic. The two are different numbers on any line whose
    gross does not land on a whole cent (0.750 kg at 5.50 is a gross of 4.1250:
    the line stores 4.12, the raw product keeps 4.1250), and the refund that
    reverses a sale is always the document's own ``OrderAdjustment.amount``. Mix
    the two and a sale that is entirely undone leaves a residue of profit behind
    on goods the shop no longer sold — and the same report ends up stating two
    different revenues, so ``net_sales - gross_profit`` is not the cost of
    anything.

    ``sold_cost`` is the raw ``Sum(SOLD_COST_EXPRESSION)`` the caller already
    aggregated alongside its other line figures; it is rounded here, once, so it
    matches ``returned_cost_total`` term for term.
    """
    cost = (Decimal(sold_cost or 0)).quantize(Decimal("0.01"))
    return (
        Decimal(revenue or 0)
        - cost
        - Decimal(refund_total or 0)
        + returned_cost_total(adjustments)
    ).quantize(Decimal("0.01"))


class TradeIn(TimeStampedModel):
    """Links the two legs of a trade-in into one audited operation.

    The purchase of the article the customer handed over and the sale of the one
    they walked out with are two real documents, each correct on its own; this
    row is what makes the pair discoverable as the single thing that actually
    happened. Deliberately the same shape as :class:`OrderExchange`, which
    solved the same problem for return-and-replace.
    """

    purchase_order = models.OneToOneField(
        "purchasing.PurchaseOrder",
        on_delete=models.PROTECT,
        related_name="trade_in",
    )
    order = models.OneToOneField(
        Order,
        on_delete=models.PROTECT,
        related_name="trade_in",
    )
    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="trade_ins",
    )
    #: What the incoming article was valued at, what the outgoing sale came to,
    #: and what the customer actually settled (positive = they paid the
    #: difference).
    trade_in_amount = models.DecimalField(max_digits=10, decimal_places=2)
    sale_amount = models.DecimalField(max_digits=10, decimal_places=2)
    net_amount = models.DecimalField(max_digits=10, decimal_places=2)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="trade_ins",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at", "-id"]

    def __str__(self) -> str:
        return f"trade-in {self.purchase_order_id} → {self.order_id}"


class OrderExchange(TimeStampedModel):
    """Links the two legs of a sales exchange into one audited operation.

    A sales exchange is modelled as a RETURN of the original line(s) plus a fresh
    SALE of the replacement item(s) — two real, independently-correct documents,
    so revenue, COGS, profit, stock and the cash drawer all reconcile through the
    existing return + checkout machinery (see services.exchange_order_items). This
    row ties them together and records the net money the customer settled, so the
    pair is discoverable and auditable as a single exchange (parallel to the
    purchasing side's PurchaseOrderAdjustment of type EXCHANGE).
    """

    original_order = models.ForeignKey(
        Order,
        on_delete=models.PROTECT,
        related_name="exchanges",
    )
    return_adjustment = models.OneToOneField(
        OrderAdjustment,
        on_delete=models.PROTECT,
        related_name="exchange",
    )
    replacement_order = models.OneToOneField(
        Order,
        on_delete=models.PROTECT,
        related_name="exchange_source",
    )
    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="order_exchanges",
    )
    # Value of the returned goods (= return_adjustment.amount), the replacement
    # goods (replacement_order.total), and the net the customer settled
    # (replacement_amount - outbound_amount): positive = customer paid the
    # difference, negative = refunded to the customer, zero = even exchange.
    outbound_amount = models.DecimalField(max_digits=10, decimal_places=2)
    replacement_amount = models.DecimalField(max_digits=10, decimal_places=2)
    net_amount = models.DecimalField(max_digits=10, decimal_places=2)
    settlement_method = models.CharField(max_length=16, default="cash")
    reason = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="order_exchanges",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"exchange net {self.net_amount} for {self.original_order_id}"


class StockReservation(TimeStampedModel):
    """A hold placed on stock by a quotation (فاتورة عرض).

    The sum of a variant's ACTIVE reservations equals its
    ``StockItem.quantity_committed``; this row is the per-quote audit ledger
    (which quote, how much, until when). Availability for selling is
    ``quantity_on_hand - quantity_committed``, so a reservation never moves
    on-hand — it only blocks others from dipping into the held units.

    Lives in ``sales`` (FK to ``inventory.StockItem`` by string) so the app
    dependency arrow stays sales → inventory, never the reverse.
    """

    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        RELEASED = "released", "Released"
        CONSUMED = "consumed", "Consumed"

    # Where the hold was placed. A release that came off the shop's default
    # while the hold went on the store room would leave committed quantity
    # drifting upward in one place and downward in another, permanently and
    # silently. Required since ``0030``; defaulted in ``save``.
    warehouse = models.ForeignKey(
        "inventory.Warehouse",
        on_delete=models.PROTECT,
        related_name="stock_reservations",
        blank=True,
    )
    order = models.ForeignKey(
        Order,
        on_delete=models.CASCADE,
        related_name="stock_reservations",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="stock_reservations",
    )
    stock_item = models.ForeignKey(
        "inventory.StockItem",
        on_delete=models.PROTECT,
        related_name="reservations",
    )
    base_quantity = models.DecimalField(
        max_digits=12,
        decimal_places=3,
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.ACTIVE,
    )
    expires_at = models.DateField(blank=True, null=True)

    def save(self, *args, **kwargs):
        if self.warehouse_id is None:
            from apps.inventory.models import Warehouse

            self.warehouse_id = Warehouse.default_id()
            if (
                self.warehouse_id is not None
                and kwargs.get("update_fields") is not None
            ):
                kwargs["update_fields"] = [*kwargs["update_fields"], "warehouse"]
        return super().save(*args, **kwargs)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(
                fields=["status", "expires_at"],
                name="sales_reservation_status_idx",
            ),
        ]

    def __str__(self) -> str:
        return (
            f"reservation {self.base_quantity} of variant {self.variant_id} "
            f"({self.status})"
        )


def prime_register_session_cash_totals(sessions):
    """Fill the drawer-total caches for many sessions in a fixed 3 queries.

    Each of ``cash_sales_total`` / ``pay_in_total`` / ``pay_out_total`` /
    ``cash_refund_total`` is its own aggregate, and the composites re-run them:
    ``expected_cash`` reads all four, ``cash_variance`` re-reads
    ``expected_cash``, ``has_cash_variance`` re-reads ``cash_variance``. A closed
    session therefore costs 16 queries to serialize, so a 10-row page cost 160.
    Batching the *fetching* here (the arithmetic stays in the properties) makes
    that flat.

    Measured on ``register-session-list`` with a sale, a pay-in, a pay-out and a
    close per session: 16.0 queries/row -> 0.0 (5 rows 84 -> 7, 10 rows 164 -> 7).
    """
    sessions = list(sessions)
    ids = [session.pk for session in sessions if session.pk is not None]
    if not ids:
        return sessions

    from apps.payments.models import Payment

    zero = Decimal("0.00")
    cash_sales = {
        row["register_session_id"]: row["total"] or zero
        for row in (
            Payment.objects.filter(
                register_session_id__in=ids,
                method=Payment.Method.CASH,
                amount__gt=0,
            )
            .values("register_session_id")
            .annotate(total=Sum("amount"))
        )
    }
    cash_refunds = {
        row["register_session_id"]: row["total"] or zero
        for row in (
            OrderAdjustment.objects.filter(register_session_id__in=ids)
            .values("register_session_id")
            .annotate(total=Sum("cash_amount"))
        )
    }
    # Both movement directions come back from one grouped query keyed on
    # (session, type) — the properties split them apart again below.
    movements = {
        (row["register_session_id"], row["movement_type"]): row["total"] or zero
        for row in (
            RegisterCashMovement.objects.filter(register_session_id__in=ids)
            .values("register_session_id", "movement_type")
            .annotate(total=Sum("amount"))
        )
    }

    pay_in = RegisterCashMovement.MovementType.PAY_IN
    pay_out = RegisterCashMovement.MovementType.PAY_OUT
    for session in sessions:
        session._cash_sales_total = cash_sales.get(session.pk, zero).quantize(
            Decimal("0.01")
        )
        session._cash_refund_total = cash_refunds.get(session.pk, zero).quantize(
            Decimal("0.01")
        )
        session._pay_in_total = movements.get((session.pk, pay_in), zero).quantize(
            Decimal("0.01")
        )
        session._pay_out_total = movements.get((session.pk, pay_out), zero).quantize(
            Decimal("0.01")
        )
    return sessions


class RegisterProfile(TimeStampedModel):
    """What one till is set up to do — ERPNext's POS Profile, at our scale.

    Today it answers one question: **which place does this till sell out of?**
    A shop with a showroom and a store room puts a register on the shop floor
    and expects it to sell the shop floor's stock, not the sum of both.

    Keyed on the device rather than the cashier, because the warehouse is a
    property of where the till is standing, not of who is standing at it — the
    same till sells the same shelves whoever is on shift. The client already
    keeps a stable ``device_id`` and already sends it as ``X-Pointy-Device-Id``.

    **A shop that never opens a second warehouse never gets one of these rows.**
    No profile means the shop's default warehouse, which is what every till has
    always sold from — so an app that has never heard of warehouses keeps
    working unchanged, and a shop mid-upgrade does not need anyone to configure
    anything before the next customer is served.
    """

    device_id = models.CharField(max_length=120, unique=True)
    name = models.CharField(max_length=120, blank=True)
    warehouse = models.ForeignKey(
        "inventory.Warehouse",
        on_delete=models.PROTECT,
        related_name="register_profiles",
    )
    last_seen_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["name", "device_id"]

    def __str__(self) -> str:
        return self.name or self.device_id
