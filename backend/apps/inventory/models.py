from decimal import Decimal

from django.conf import settings
from django.db import DatabaseError, models
from django.db.models import F, Q

from apps.catalog.models import ProductVariant
from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin

#: What a shop's one and only location is called until it opens a second. The
#: showroom, not the store room: naming a single-location shop's floor "the main
#: warehouse" describes a back room they have not got.
DEFAULT_WAREHOUSE_NAME = "المعرض"

#: Where goods sit while they are on the road between two of a shop's places.
TRANSIT_WAREHOUSE_NAME = "في الطريق"

#: The default warehouse's ``(id, oversell policy)``, per database alias.
#: Invalidated by ``apps.inventory.signals`` on any warehouse write and on
#: ``post_migrate`` — the latter matters because ``TransactionTestCase`` flushes
#: the table and Django re-emits the signal afterwards, so without it a cached
#: id would outlive the row it names.
_DEFAULT_WAREHOUSE: dict = {}


def forget_default_warehouse():
    _DEFAULT_WAREHOUSE.clear()


class StockItem(TimeStampedModel):
    """How much of one variant sits in one place.

    ERPNext calls this ``Bin``; that word is already spoken for here by
    ``StockValuationBin``, which is the same idea for *value*. This is the
    quantity half, and until 2026-09-06 it was a ``OneToOneField`` — exactly one
    bucket per variant, globally, with nowhere to say a showroom holds three and
    the store room holds forty.

    Where ERPNext's ``Bin`` carries nine quantity fields (four of them for
    manufacturing we will never build), this carries three, and they are the
    three a shop actually asks about: what is here, what is spoken for, and what
    is on its way.
    """

    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="stock_items",
    )
    # PROTECT, not CASCADE: deleting a location must never become a way to
    # delete the stock standing in it. ERPNext enforces the same rule from the
    # other end, in ``Warehouse.on_trash``, and so do we — see
    # ``Warehouse.deletion_blockers``.
    # Nullable for exactly one release, and not because null means anything.
    # Expanded nullable in ``0018`` because a live update runs the old backend
    # against the new schema for about a minute, and that backend inserted stock
    # rows knowing nothing about warehouses — on this table, a NOT NULL column
    # would have meant a till that cannot sell. ``0023`` contracted it once a
    # release had shipped in between.
    #
    # ``blank=True`` stays, and is not an oversight: it is the *serializer*
    # saying callers need not supply a location, while the database says a row
    # may not lack one. ``save`` bridges the two. Dropping it turned a schema
    # contract into a breaking API change — 111 tests, every caller that had
    # never named a warehouse suddenly getting a 400.
    warehouse = models.ForeignKey(
        "inventory.Warehouse",
        on_delete=models.PROTECT,
        related_name="stock_items",
        blank=True,
    )
    quantity_on_hand = models.DecimalField(max_digits=12, decimal_places=3, default=0)
    quantity_committed = models.DecimalField(max_digits=12, decimal_places=3, default=0)
    quantity_expected = models.DecimalField(max_digits=12, decimal_places=3, default=0)
    reorder_level = models.PositiveIntegerField(default=5)

    class Meta:
        ordering = ["variant__product__name", "variant__name"]
        constraints = [
            models.UniqueConstraint(
                fields=["variant", "warehouse"],
                name="stock_item_variant_warehouse_unique",
            ),
        ]

    def save(self, *args, **kwargs):
        """A stock row always lands somewhere.

        The column was nullable for one release so an older backend's inserts
        could survive a live update; ``0023`` filled the gaps and made it
        required, so a null is now a database error rather than a silent hole.
        This default stays regardless: it is what lets every existing caller —
        and every existing test fixture — keep creating stock rows exactly as it
        did before locations existed.
        """
        if self.warehouse_id is None:
            self.warehouse_id = Warehouse.default_id()
            if (
                self.warehouse_id is not None
                and kwargs.get("update_fields") is not None
            ):
                kwargs["update_fields"] = [*kwargs["update_fields"], "warehouse"]
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.variant.sku} @ {self.warehouse_id}: {self.quantity_on_hand}"


class StockMovement(TimeStampedModel):
    class Type(models.TextChoices):
        INCREASE = "increase", "Increase stock"
        DECREASE = "decrease", "Decrease stock"
        DAMAGED = "damaged", "Damaged stock"
        EXPECTED = "expected", "Expected stock"
        RECEIVE_EXPECTED = "receive_expected", "Receive expected stock"
        RECEIVE_DAMAGED = "receive_damaged", "Receive damaged expected stock"
        CANCEL_EXPECTED = "cancel_expected", "Cancel expected stock"
        TRANSFER_OUT = "transfer_out", "Sent to another warehouse"
        TRANSFER_IN = "transfer_in", "Received from another warehouse"

    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="stock_movements",
    )
    stock_item = models.ForeignKey(
        StockItem,
        on_delete=models.CASCADE,
        related_name="movements",
    )
    # Denormalised from ``stock_item`` so a movement says where it happened
    # without a join. The valuation engine groups by it, and it is read once per
    # movement on the busiest write path in the shop — reaching through the
    # stock row for it would be a query per line. Required since ``0023``,
    # which backfilled every movement from the stock row it moved; ``save``
    # still fills it so no caller has to.
    warehouse = models.ForeignKey(
        "inventory.Warehouse",
        on_delete=models.PROTECT,
        related_name="stock_movements",
        blank=True,
    )
    movement_type = models.CharField(max_length=32, choices=Type.choices)
    quantity = models.DecimalField(max_digits=12, decimal_places=3)
    note = models.CharField(max_length=240, blank=True)
    created_by = models.ForeignKey(
        "auth.User",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="stock_movements",
    )
    on_hand_before = models.DecimalField(max_digits=12, decimal_places=3)
    on_hand_after = models.DecimalField(max_digits=12, decimal_places=3)
    committed_before = models.DecimalField(max_digits=12, decimal_places=3)
    committed_after = models.DecimalField(max_digits=12, decimal_places=3)
    expected_before = models.DecimalField(max_digits=12, decimal_places=3)
    expected_after = models.DecimalField(max_digits=12, decimal_places=3)

    def save(self, *args, **kwargs):
        if self.warehouse_id is None and self.stock_item_id is not None:
            self.warehouse_id = self.stock_item.warehouse_id
        return super().save(*args, **kwargs)

    class Meta:
        ordering = ["-created_at", "-id"]

    def __str__(self) -> str:
        return f"{self.variant.sku} {self.movement_type} {self.quantity}"


class StockBatch(TimeStampedModel):
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="stock_batches",
    )
    source_receipt_line = models.OneToOneField(
        "purchasing.PurchaseReceiptLine",
        on_delete=models.PROTECT,
        related_name="stock_batch",
    )
    expiry_date = models.DateField(db_index=True)
    received_quantity = models.DecimalField(max_digits=12, decimal_places=3)
    remaining_quantity = models.DecimalField(max_digits=12, decimal_places=3)

    class Meta:
        ordering = ["expiry_date", "created_at", "id"]
        indexes = [
            models.Index(
                fields=["variant", "expiry_date", "remaining_quantity"],
                name="stockbatch_variant_expiry_idx",
            ),
            models.Index(
                fields=["expiry_date", "remaining_quantity"],
                name="stockbatch_exp_remain_idx",
            ),
        ]
        constraints = [
            models.CheckConstraint(
                condition=Q(remaining_quantity__lte=F("received_quantity")),
                name="stock_batch_remaining_lte_received",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.variant.sku} expires {self.expiry_date}"


class Warehouse(TimeStampedModel):
    """A place stock physically sits.

    **Flat, on purpose.** ERPNext models warehouses as a nested-set tree with
    interior "group" nodes that cannot hold stock, and pays for it with a
    standing class of confusion — posting to a group, converting a node that has
    transactions, conversion that half-succeeds. Four of the thirteen tests in
    their ``test_warehouse.py`` exist only to hold the tree together. A tree is
    the right answer for plants, regions and racks; it is the wrong answer for a
    shop with a showroom, a store room and possibly a van. If a customer ever
    needs a hierarchy it is a clean schema addition, bought by that customer
    rather than guessed at now.

    **One of them, by default.** Every shop starts with exactly one warehouse
    and it is the shop floor — most shops in Libya are a single showroom with no
    back store at all. A store room is something a shop *adds*; nothing creates
    one on its behalf.
    """

    class Kind(models.TextChoices):
        SHOP_FLOOR = "shop_floor", "Shop floor"
        STORE_ROOM = "store_room", "Store room"
        VAN = "van", "Van"
        # Where goods live between leaving one place and arriving at another.
        # Not a place anyone sells from, and the transfer document refuses to
        # dispatch *into* one by accident.
        TRANSIT = "transit", "In transit"

    class OversellPolicy(models.TextChoices):
        SHOP_DEFAULT = "shop_default", "Follow the shop setting"
        ALLOW = "allow", "Allow selling below zero"
        REFUSE = "refuse", "Refuse selling below zero"

    name = models.CharField(max_length=120)
    code = models.SlugField(max_length=32, unique=True)
    kind = models.CharField(
        max_length=16, choices=Kind.choices, default=Kind.SHOP_FLOOR,
        db_default=Kind.SHOP_FLOOR,
    )
    # ERPNext's negative-stock switch is per *company*, and issue #12651 is a
    # standing request to make it per warehouse that nobody has closed. Worse,
    # #45414 reports invoices submitting below zero while the switch is off,
    # because an item-level flag interacts with the global one and one path
    # forgets to check. So: one policy, per place, resolved by one function,
    # falling back to the shop setting — the shape ``credit_limit_policy``
    # already uses here.
    allow_overselling = models.CharField(
        max_length=16, choices=OversellPolicy.choices,
        default=OversellPolicy.SHOP_DEFAULT, db_default=OversellPolicy.SHOP_DEFAULT,
    )
    is_default = models.BooleanField(default=False, db_index=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["-is_default", "name", "id"]

    def __str__(self) -> str:
        return self.name

    @property
    def sells_from(self) -> bool:
        """Whether a till may sell out of here. Transit is a state, not a shop."""
        return self.kind != self.Kind.TRANSIT

    @classmethod
    def default_id(cls):
        """Primary key of the default warehouse, creating it if it is missing.

        Self-healing on purpose: a shop restored from a backup taken before the
        warehouse migration must not lose the ability to sell.

        Cached, because this is asked several times inside one checkout — the
        valuation engine alone resolves it three times per sale — and the
        cashier waits on every one of them. What is cached is a pair of
        primitives, never the model instance: a cached instance that some caller
        mutates without saving is how a singleton cache poisons the next
        request, and ``caching.get_shop_settings`` already carries that scar.
        """
        return cls._default_row()[0]

    @classmethod
    def transit_id(cls):
        """The one place goods live between leaving here and arriving there.

        Created on demand rather than seeded, because a shop that never
        transfers anything should never see a location it did not open. One per
        shop rather than one per transfer: what is on the road is attributable
        to a transfer through its own lines, and a warehouse per transfer would
        be a table of empty rooms.
        """
        row = (
            cls.objects.filter(kind=cls.Kind.TRANSIT)
            .order_by("id")
            .values_list("id", flat=True)
            .first()
        )
        if row is not None:
            return row
        warehouse, _ = cls.objects.get_or_create(
            code="transit",
            defaults={"name": TRANSIT_WAREHOUSE_NAME, "kind": cls.Kind.TRANSIT},
        )
        return warehouse.pk

    @classmethod
    def default_oversell_policy(cls):
        """The default warehouse's own policy, from the same cached read."""
        return cls._default_row()[1]

    @classmethod
    def _default_row(cls):
        cached = _DEFAULT_WAREHOUSE.get(cls.objects.db)
        if cached is not None:
            return cached
        try:
            row = (
                cls.objects.filter(is_default=True)
                .values_list("id", "allow_overselling")
                .first()
            )
            if row is None:
                warehouse, _ = cls.objects.get_or_create(
                    code="main",
                    defaults={"name": DEFAULT_WAREHOUSE_NAME, "is_default": True},
                )
                row = (warehouse.pk, warehouse.allow_overselling)
        except DatabaseError:
            # This table cannot be read or written in its current shape. In
            # practice that means one thing: a test that rewound this app to
            # exercise a historical migration, so the live model names columns
            # the table has not got yet.
            #
            # The honest answer is "no warehouse", not a crash. Every column
            # this phase adds is nullable for exactly one release, so a row
            # written without one is a row ``apps.inventory.reconciliation``
            # adopts on the next ``post_migrate`` — which is the same path an
            # older backend's inserts take during a live update. Nothing is
            # cached, so the next call after the schema catches up gets a real
            # answer.
            return (None, cls.OversellPolicy.SHOP_DEFAULT)
        _DEFAULT_WAREHOUSE[cls.objects.db] = row
        return row

    def deletion_blockers(self):
        """Why this warehouse cannot be deleted, or an empty list.

        Ported from ERPNext's ``Warehouse.on_trash``, minus the child-warehouse
        clause we have no tree to need, and with one divergence: where they
        *unlink* a deleted warehouse from anything that named it as a default,
        we refuse. Silently detaching a reference is how a shop discovers later
        that a number moved.
        """
        blockers = []
        if self.is_default:
            blockers.append("the default warehouse cannot be deleted")

        # Answered from annotations when the caller made them. This is asked
        # once per row on the warehouse list — the ``blockers`` field is what
        # lets the UI grey out a delete button instead of offering one that
        # fails — and unannotated it is two queries per warehouse.
        held = getattr(self, "blocking_stock_count", None)
        if held is None:
            held = self.stock_items.exclude(
                quantity_on_hand=0, quantity_committed=0, quantity_expected=0
            ).count()
        if held:
            blockers.append(f"{held} product(s) still hold stock here")

        has_history = getattr(self, "has_stock_history", None)
        if has_history is None:
            has_history = self.ledger_entries.exists()
        if has_history:
            blockers.append("stock history was recorded here")
        return blockers

    #: Everything ``deletion_blockers`` needs, in one statement.
    @staticmethod
    def blocker_annotations():
        from django.db.models import Count, Exists, OuterRef, Q

        return {
            "blocking_stock_count": Count(
                "stock_items",
                filter=~Q(
                    stock_items__quantity_on_hand=0,
                    stock_items__quantity_committed=0,
                    stock_items__quantity_expected=0,
                ),
                distinct=True,
            ),
            "has_stock_history": Exists(
                StockLedgerEntry.objects.filter(warehouse=OuterRef("pk"))
            ),
        }


class StockValuationBin(TimeStampedModel):
    """The live valuation state for one variant in one warehouse.

    This is ERPNext's ``Bin`` in miniature: a cache of the ledger that exists so
    a checkout does not have to replay history to learn what a sale costs. The
    ledger is the truth; this row can always be rebuilt from it
    (``repost_valuation``).

    ``state`` is the valuation engine's own state — the ``[[qty, rate], ...]``
    queue for FIFO/LIFO, or a single blended bin for moving average — stored as
    strings so a Decimal never round-trips through a float.
    """

    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="valuation_bins",
    )
    warehouse = models.ForeignKey(
        Warehouse,
        on_delete=models.PROTECT,
        related_name="valuation_bins",
    )
    quantity = models.DecimalField(max_digits=14, decimal_places=3, default=0)
    valuation_rate = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    stock_value = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    state = models.JSONField(default=list, blank=True)
    # The method that produced ``state``. A change of method has to rebuild the
    # state rather than keep consuming a queue the new method cannot read.
    method = models.CharField(max_length=20, default="moving_average")

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["variant", "warehouse"],
                name="stock_valuation_bin_unique",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.variant.sku} @ {self.warehouse.code}: {self.valuation_rate}"


class StockLedgerEntry(TimeStampedModel):
    """One valued stock event: what moved, at what cost, and what is left.

    Append-only. ``StockMovement`` records that a quantity changed and who did
    it; this records what that change was *worth*, which is what gross profit,
    stock value and the loss guard actually need. Ported in spirit from
    ERPNext's Stock Ledger Entry.

    ``value_change`` is the money that moved: for an issue it is the cost of
    goods sold, computed by the valuation engine from the bins actually
    consumed, not from whatever the item last cost to buy.
    """

    class VoucherType(models.TextChoices):
        SALE = "sale", "Sale"
        SALE_RETURN = "sale_return", "Sale return"
        PURCHASE_RECEIPT = "purchase_receipt", "Purchase receipt"
        PURCHASE_RETURN = "purchase_return", "Purchase return"
        PRODUCTION = "production", "Production"
        STOCK_COUNT = "stock_count", "Stock count"
        ADJUSTMENT = "adjustment", "Manual adjustment"
        OPENING = "opening", "Opening balance"
        TRANSFER = "transfer", "Warehouse transfer"
        TRANSFER_RECEIPT = "transfer_receipt", "Warehouse transfer receipt"

    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="ledger_entries",
    )
    warehouse = models.ForeignKey(
        Warehouse,
        on_delete=models.PROTECT,
        related_name="ledger_entries",
    )
    movement = models.OneToOneField(
        StockMovement,
        on_delete=models.CASCADE,
        related_name="ledger_entry",
        null=True,
        blank=True,
    )
    posting_at = models.DateTimeField(db_index=True)
    # Signed: positive received, negative issued. Always in base units.
    quantity_change = models.DecimalField(max_digits=14, decimal_places=3)
    # The rate this entry moved at: the purchase cost for a receipt, the
    # blended cost of the consumed bins for an issue.
    valuation_rate = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    value_change = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    balance_quantity = models.DecimalField(max_digits=14, decimal_places=3, default=0)
    balance_value = models.DecimalField(max_digits=18, decimal_places=6, default=0)
    # Engine state after this entry, so history can be inspected and a repost
    # can resume from any point instead of always replaying from the beginning.
    state = models.JSONField(default=list, blank=True)
    method = models.CharField(max_length=20, default="moving_average")
    voucher_type = models.CharField(
        max_length=24,
        choices=VoucherType.choices,
        default=VoucherType.ADJUSTMENT,
        db_index=True,
    )
    voucher_id = models.PositiveBigIntegerField(null=True, blank=True, db_index=True)
    note = models.CharField(max_length=240, blank=True)

    class Meta:
        ordering = ["posting_at", "id"]
        indexes = [
            models.Index(
                fields=["variant", "warehouse", "posting_at", "id"],
                name="sle_variant_wh_posting_idx",
            ),
            models.Index(
                fields=["voucher_type", "voucher_id"],
                name="sle_voucher_idx",
            ),
        ]

    def __str__(self) -> str:
        return (
            f"{self.variant_id} {self.quantity_change:+} @ {self.valuation_rate}"
        )


class StockCountQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class StockCount(DocumentMixin, TimeStampedModel):
    """A physical inventory count session.

    Mirrors the ``RegisterSession`` open->closed lifecycle: a session is opened
    (``in_progress``), counted item-by-item through ``StockCountLine`` rows, then
    either ``applied`` (variances written to stock as ``StockMovement`` rows) or
    ``cancelled``. A user may only have one ``in_progress`` count at a time so the
    "resume" path is unambiguous.
    """

    objects = StockCountQuerySet.as_manager()

    class Status(models.TextChoices):
        """Where the count has got to. Derived from ``doc_status`` by
        ``apps.inventory.documents.recompute_progress`` and written nowhere
        else: counting is the draft, applying is the submission."""

        IN_PROGRESS = "in_progress", "In progress"
        APPLIED = "applied", "Applied"
        CANCELLED = "cancelled", "Cancelled"

    class Scope(models.TextChoices):
        FULL = "full", "Full shop"
        CATEGORY = "category", "Single category"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="stock_counts",
        blank=True,
        null=True,
    )
    owner_key = models.CharField(max_length=64, db_index=True)
    # A count is of one place. Counting "the shop" while stock sits in a store
    # room out the back is how a variance report becomes fiction: every unit in
    # the back reads as missing from the front. Required since ``0023``;
    # ``save`` still defaults it so no path of ours has to name a location it
    # does not care about.
    warehouse = models.ForeignKey(
        "inventory.Warehouse",
        on_delete=models.PROTECT,
        related_name="stock_counts",
        blank=True,
    )
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.IN_PROGRESS,
    )
    scope = models.CharField(
        max_length=16,
        choices=Scope.choices,
        default=Scope.FULL,
    )
    category = models.ForeignKey(
        "catalog.ProductCategory",
        on_delete=models.PROTECT,
        related_name="stock_counts",
        blank=True,
        null=True,
    )
    note = models.CharField(max_length=240, blank=True)
    # Denominator for the "X of Y" progress, frozen at start so the total does
    # not drift if the catalog changes mid-count.
    expected_line_count = models.PositiveIntegerField(default=0)
    applied_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="applied_stock_counts",
        blank=True,
        null=True,
    )
    # The count's dialect of ``submitted_at``/``submitted_by``, kept because the
    # API exposes them; mirrored from the lifecycle rather than written beside
    # it. ``cancelled_at`` now comes from DocumentMixin — the same column, with
    # the person who cancelled beside it.
    applied_at = models.DateTimeField(blank=True, null=True)

    def save(self, *args, **kwargs):
        """A count always names the place it counted.

        Same reasoning as ``StockItem.save``: the column stays nullable for one
        release so an older backend can still write during a flip, but nothing
        of ours may leave it unset — a count with no location cannot be
        reconciled against anything.
        """
        if self.warehouse_id is None:
            self.warehouse_id = Warehouse.default_id()
            if (
                self.warehouse_id is not None
                and kwargs.get("update_fields") is not None
            ):
                kwargs["update_fields"] = [*kwargs["update_fields"], "warehouse"]
        return super().save(*args, **kwargs)

    class Meta:
        ordering = ["-created_at", "-id"]
        permissions = [
            ("apply_stockcount", "Can apply stock count adjustments"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["owner_key"],
                condition=Q(status="in_progress"),
                name="unique_in_progress_stock_count_per_owner",
            )
        ]
        indexes = [
            models.Index(fields=["status", "-created_at"]),
        ]

    def __str__(self) -> str:
        return f"{self.owner_key} {self.status} stock count"

    @property
    def count_number(self) -> str:
        if self.pk is None:
            return "SC"
        return f"SC-{self.pk}"


class StockCountLine(TimeStampedModel):
    stock_count = models.ForeignKey(
        StockCount,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="stock_count_lines",
    )
    counted_quantity = models.DecimalField(max_digits=12, decimal_places=3)
    # Snapshot of on_hand at the moment this line was counted (re-snapshotted on
    # every edit). It backs the variance prompt and the apply-time delta.
    expected_quantity = models.DecimalField(max_digits=12, decimal_places=3)
    counted_at = models.DateTimeField()
    counted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="stock_count_lines",
        blank=True,
        null=True,
    )
    needs_review = models.BooleanField(default=False)
    movement = models.ForeignKey(
        "inventory.StockMovement",
        on_delete=models.SET_NULL,
        related_name="stock_count_lines",
        blank=True,
        null=True,
    )
    applied = models.BooleanField(default=False)
    # Set at apply time: True when on_hand moved between counted_at and apply
    # (e.g. a sale landed mid-count). We flag, never freeze.
    stale_at_apply = models.BooleanField(default=False)
    on_hand_at_apply = models.DecimalField(
        max_digits=12,
        decimal_places=3,
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["variant__product__name", "variant__name", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["stock_count", "variant"],
                name="unique_variant_per_stock_count",
            )
        ]
        indexes = [
            models.Index(fields=["stock_count", "needs_review"]),
        ]

    def __str__(self) -> str:
        return f"{self.stock_count_id}:{self.variant.sku} = {self.counted_quantity}"

    @property
    def variance(self):
        return self.counted_quantity - self.expected_quantity


class StockTransferQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class StockTransfer(DocumentMixin, TimeStampedModel):
    """Goods moving from one of a shop's places to another.

    **Two documents and a transit location, not one atomic move.** SAP, Oracle
    and Odoo all converged on this shape, and the reason is physical rather than
    architectural: goods in a van are somewhere. A transfer that debits the
    source and credits the destination in a single step values them in neither
    place while they are on the road, so the shop's stock value dips for as long
    as the driver is out.

    So: this document is the **dispatch**. Submitting it takes stock out of the
    source and puts it in transit. A ``StockTransferReceipt`` referencing it
    takes stock out of transit and puts it at the destination. Cancelling the
    dispatch brings it back from transit, and is refused while any receipt still
    stands — you undo the arrival first, deliberately, rather than having a
    cascade quietly reach into the destination's shelves.

    Where ERPNext models all of this as one ``Stock Entry`` doctype with a
    seven-valued ``purpose`` and validation dispatched at runtime, five of those
    purposes are manufacturing and subcontracting we refuse outright. One
    document that does one thing.
    """

    objects = StockTransferQuerySet.as_manager()

    class Status(models.TextChoices):
        """Where the goods have got to. Derived from ``doc_status`` and the
        receipts by ``apps.inventory.documents``, and written nowhere else."""

        DRAFT = "draft", "Draft"
        IN_TRANSIT = "in_transit", "In transit"
        PARTIALLY_RECEIVED = "partially_received", "Partially received"
        RECEIVED = "received", "Received"
        CANCELLED = "cancelled", "Cancelled"

    transfer_number = models.CharField(max_length=32, unique=True, blank=True)
    source = models.ForeignKey(
        Warehouse, on_delete=models.PROTECT, related_name="transfers_out"
    )
    destination = models.ForeignKey(
        Warehouse, on_delete=models.PROTECT, related_name="transfers_in"
    )
    status = models.CharField(
        max_length=24, choices=Status.choices, default=Status.DRAFT
    )
    note = models.CharField(max_length=240, blank=True)
    # The transfer's dialect of ``submitted_at``/``submitted_by``, mirrored from
    # the lifecycle rather than written beside it — the same arrangement
    # ``StockCount.applied_at`` uses.
    dispatched_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        permissions = [
            ("dispatch_stocktransfer", "Can send stock between warehouses"),
            ("receive_stocktransfer", "Can receive transferred stock"),
        ]
        indexes = [
            models.Index(fields=["status", "-created_at"]),
        ]
        constraints = [
            models.CheckConstraint(
                condition=~Q(source=F("destination")),
                name="stock_transfer_source_is_not_destination",
            ),
        ]

    def save(self, *args, **kwargs):
        if not self.transfer_number:
            # Derived from the row's own id, so it can only be stamped once the
            # insert has happened — two saves, one creation. Exactly what
            # ``PurchaseOrder`` does, and for the same reason: a blank number is
            # not a number, and two blanks collide on the unique index.
            from django.db import transaction

            from apps.documents.guards import system_write

            with transaction.atomic():
                super().save(*args, **kwargs)
                self.transfer_number = f"T{self.created_at:%Y%m%d}{self.id:06d}"
                with system_write():
                    return super().save(update_fields=["transfer_number"])
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.transfer_number or self.pk}: {self.source_id}->{self.destination_id}"

    @property
    def outstanding_lines(self):
        return [line for line in self.lines.all() if line.outstanding_quantity > 0]


class StockTransferLine(TimeStampedModel):
    transfer = models.ForeignKey(
        StockTransfer, on_delete=models.CASCADE, related_name="lines"
    )
    variant = models.ForeignKey(
        ProductVariant, on_delete=models.PROTECT, related_name="transfer_lines"
    )
    quantity = models.DecimalField(max_digits=12, decimal_places=3)
    # The unit this line is moved in (a UnitOfMeasure.code); blank = the
    # product's base unit. ``unit_factor`` snapshots how many base units one of
    # them is worth, exactly as ``PurchaseLine`` does, and the conversion
    # happens only at the stock boundary.
    unit = models.CharField(max_length=32, blank=True, default="")
    unit_factor = models.DecimalField(
        max_digits=12, decimal_places=3, default=Decimal("1")
    )
    #: Base units already taken out of transit by a receipt.
    received_quantity = models.DecimalField(
        max_digits=12, decimal_places=3, default=0
    )

    class Meta:
        ordering = ["id"]

    def to_base_quantity(self, quantity) -> Decimal:
        """A quantity in this line's unit → the product's base unit."""
        return (Decimal(quantity) * self.unit_factor).quantize(Decimal("0.001"))

    @property
    def base_quantity(self) -> Decimal:
        return self.to_base_quantity(self.quantity)

    @property
    def outstanding_quantity(self) -> Decimal:
        """Base units still on the road."""
        return max(self.base_quantity - self.received_quantity, Decimal("0.000"))


class StockTransferReceiptQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class StockTransferReceipt(DocumentMixin, TimeStampedModel):
    """Goods arriving at the far end of a transfer.

    Its own document rather than a flag on the transfer, for the same reason
    ``PurchaseReceipt`` is its own document: a delivery that arrives in two
    loads is two events, each with its own date, its own person and its own
    reversal. Born submitted — there is no draft arrival.
    """

    objects = StockTransferReceiptQuerySet.as_manager()

    transfer = models.ForeignKey(
        StockTransfer, on_delete=models.PROTECT, related_name="receipts"
    )
    note = models.CharField(max_length=240, blank=True)

    class Meta:
        ordering = ["-created_at", "-id"]

    def __str__(self) -> str:
        return f"receipt for {self.transfer_id}"


class StockTransferReceiptLine(TimeStampedModel):
    receipt = models.ForeignKey(
        StockTransferReceipt, on_delete=models.CASCADE, related_name="lines"
    )
    transfer_line = models.ForeignKey(
        StockTransferLine, on_delete=models.PROTECT, related_name="receipt_lines"
    )
    variant = models.ForeignKey(
        ProductVariant, on_delete=models.PROTECT, related_name="transfer_receipt_lines"
    )
    #: Base units. Receipts speak base units because transit does.
    quantity = models.DecimalField(max_digits=12, decimal_places=3)

    class Meta:
        ordering = ["id"]
