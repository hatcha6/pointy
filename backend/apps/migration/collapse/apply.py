"""Turning an approved plan into products, variants, units and a shelf.

The half of §12 that writes. It runs inside the ordinary import — not beside it
— because the thing that makes the collapse work at all is the identity map: if
``variant:<legacy product key>`` points at the collapsed variant before the
sales load, then four years of invoices land on the right row with no change to
the sale loader, no re-mapping pass, and no second definition of what a legacy
key means.

So this module does three things, in this order:

1. **Redirects the catalogue loaders.** A collapsed legacy product does not
   become a product; it becomes a variant of one, and a unit under that. The
   loaders for ``product``, ``variant`` and ``stock`` are wrapped rather than
   edited — a shop with no plan runs exactly the code it ran yesterday.
2. **Builds the units, last.** After the purchases, the sales and the customers,
   because a unit that knows which invoice took it and who bought it is the
   difference between importing stock and importing history.
3. **Proves it before it commits.** The §5.4 invariants are run over the
   variants this collapse touched, and a violation rolls the whole unit phase
   back. A migration is the one moment a shop cannot check the answer itself.

**What the bin is told, and by whom.** Quantity on hand for a collapsed variant
is the count of its on-hand units and nothing else — the stock entity is skipped
for these keys and reconstruction ignores them. Two authorities for one number
is how invariant 1 fails on the day of the migration; one authority, which is
the units, is how it cannot.
"""

from __future__ import annotations

import hashlib
from collections import defaultdict
from dataclasses import dataclass, field
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework.serializers import ValidationError

from apps.catalog.models import (
    Product,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
    normalize_barcode,
)
from apps.inventory import tracking
from apps.inventory.identity import normalize_identifier
from apps.inventory.integrity import tracking_invariant_violations
from apps.inventory.models import (
    StockAllocation,
    StockItem,
    StockLedgerEntry,
    StockUnit,
    StockValuationBin,
)
from apps.inventory.services import resolve_warehouse_id
from apps.inventory.unit_attributes import definitions_for, validate_attributes

from ..entity_plan import CATEGORY, PRODUCT, SALE, STOCK, SUPPLIER, VARIANT
from ..loaders.base import (
    CREATED,
    ERROR,
    FAILED,
    SKIPPED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoadOutcome,
)
from ..models import CollapseCandidate, CollapsePlan
from .extract import option_label

ZERO = Decimal("0")
ONE = Decimal("1")

#: Identity-map entity types this module owns. Namespaced so they can never
#: collide with a connector's own keys.
COLLAPSE_PRODUCT = "collapse_product"
COLLAPSE_VARIANT = "collapse_variant"
COLLAPSE_UNIT = "collapse_unit"

#: How many rows a follow-up query names at once. A migration is a batch job,
#: and a batch job that puts forty thousand ids in one ``IN`` is the shape
#: ``lifecycle-query-scaling`` is about: fine on the fixture, slow on Fahd.
CHUNK = 500

#: The variant axes the extractor produces, in the order a variant reads them.
OPTION_AXES = ("storage", "colour")
OPTION_LABELS = {"storage": "السعة", "colour": "اللون"}


@dataclass
class UnitPhaseResult:
    counts: dict = field(default_factory=dict)
    issues: list = field(default_factory=list)
    stats: dict = field(default_factory=dict)


class CollapseSession:
    """One approved plan, being applied by one run."""

    def __init__(self, plan, *, dry_run: bool, resolver=None):
        self.plan = plan
        self.dry_run = dry_run
        #: Set by the engine before the run starts. Every redirect this session
        #: performs is a write to it.
        self.resolver = resolver
        self.candidates = {
            candidate.source_key: candidate
            for candidate in plan.candidates.filter(
                decision=CollapseCandidate.Decision.COLLAPSE
            ).order_by("stem_key", "source_key", "id")
        }
        # A source with its own variant table names sale lines by the variant's
        # key, not the product's; both have to redirect to the same place.
        self.by_variant_key = {
            candidate.variant_source_key or candidate.source_key: candidate
            for candidate in self.candidates.values()
        }
        self.warehouse_id = resolve_warehouse_id(None)
        self.variant_ids: set = set()
        self._products: dict = {}
        self._variants: dict = {}
        self._definitions = None

    # --- engine hooks ----------------------------------------------------
    @classmethod
    def for_run(cls, run) -> "CollapseSession | None":
        """The plan this run was launched with, or ``None`` for an ordinary run."""
        plan_id = (run.options or {}).get("collapse_plan")
        if not plan_id:
            return None
        plan = (
            CollapsePlan.objects.filter(pk=plan_id, source_id=run.source_id)
            .select_related("asset_type")
            .first()
        )
        if plan is None or plan.status not in (
            CollapsePlan.Status.APPROVED,
            CollapsePlan.Status.APPLIED,
        ):
            return None
        return cls(plan, dry_run=run.mode == run.Mode.DRY_RUN)

    def wrap(self, loader, entity_type):
        """The loader for ``entity_type``, taught about this plan."""
        wrapper = {
            PRODUCT: _CollapsedProductLoader,
            VARIANT: _CollapsedVariantLoader,
            STOCK: _CollapsedStockLoader,
        }.get(entity_type)
        return loader if wrapper is None else wrapper(self, loader)

    def candidate_for(self, source_key):
        return self.candidates.get(str(source_key))

    def candidate_for_variant(self, source_key):
        return self.by_variant_key.get(str(source_key))

    # --- 1. catalogue ----------------------------------------------------
    def load_product(self, record, candidate, resolver) -> LoadOutcome:
        """One legacy product, landing as a variant of the product it belongs to."""
        product, created = self._ensure_product(candidate, resolver)
        self._attach_categories(product, record, resolver)
        variant = self._ensure_variant(product, candidate, resolver)
        # Everything downstream — stock, purchases, sales — asks the identity map
        # for these two keys and gets the collapsed rows.
        resolver.remember(PRODUCT, candidate.source_key, product)
        resolver.remember(VARIANT, candidate.source_key, variant)
        if candidate.variant_source_key and candidate.variant_source_key != candidate.source_key:
            resolver.remember(VARIANT, candidate.variant_source_key, variant)
        self.variant_ids.add(variant.pk)
        return LoadOutcome(CREATED if created else UPDATED, product.pk)

    def _ensure_product(self, candidate, resolver):
        cached = self._products.get(candidate.stem_key)
        if cached is not None:
            return cached, False
        product = resolver.existing(Product, COLLAPSE_PRODUCT, candidate.stem_key)
        created = product is None
        if product is None:
            product = Product()
        product.name = candidate.stem or candidate.source_name
        product.tracking_mode = Product.TrackingMode.SERIAL
        product.asset_type = self.plan.asset_type
        product.warranty_days = self.plan.warranty_days
        product.is_active = True
        product.save()
        resolver.remember(COLLAPSE_PRODUCT, candidate.stem_key, product)
        self._products[candidate.stem_key] = product
        return product, created

    def _attach_categories(self, product, record, resolver):
        resolved = [
            pk
            for pk in (
                resolver.resolve(CATEGORY, key)
                for key in (getattr(record, "category_source_keys", None) or [])
            )
            if pk is not None
        ]
        if resolved:
            # ``add``, not ``set``: a collapsed product is built from many legacy
            # rows and each one gets a say in where it belongs.
            product.categories.add(*resolved)

    def _ensure_variant(self, product, candidate, resolver):
        signature = _option_signature(candidate.options)
        cache_key = (candidate.stem_key, signature)
        cached = self._variants.get(cache_key)
        if cached is not None:
            return cached
        identity_key = _variant_identity(candidate.stem_key, signature)
        variant = resolver.existing(ProductVariant, COLLAPSE_VARIANT, identity_key)
        if variant is None:
            variant = ProductVariant(product=product, sku=_free_sku(product))
        variant.product = product
        variant.name = _variant_name(candidate.options)
        variant.unit_price = _variant_price(candidate)
        variant.is_active = True
        variant.is_default = not signature and not _has_default(product, variant)
        variant.save()
        if signature:
            _set_option_values(variant, candidate.options)
        resolver.remember(COLLAPSE_VARIANT, identity_key, variant)
        self._variants[cache_key] = variant
        return variant

    # --- 2 & 3. the unit phase ------------------------------------------
    def apply_units(self) -> UnitPhaseResult:
        """Build every unit, its history, and the shelf it sits on.

        Wrapped in its own transaction so the invariant check at the end has
        something to refuse: a collapse that would leave the bin disagreeing
        with the units it counts is rolled back whole, and the run reports it.
        A partly-identified catalogue is worse than none.
        """
        result = UnitPhaseResult(counts={CREATED: 0, UPDATED: 0, SKIPPED: 0, FAILED: 0})
        if not self.candidates:
            return result
        try:
            with transaction.atomic():
                self._build_units(result)
                self._open_the_shelf(result)
                violations = tracking_invariant_violations(variants=self.variant_ids)
                if violations:
                    raise _InvariantsViolated(violations)
        except _InvariantsViolated as refusal:
            result.counts = {CREATED: 0, UPDATED: 0, SKIPPED: 0, FAILED: len(self.candidates)}
            result.issues.append(
                Issue(
                    ERROR,
                    "collapse_invariants_violated",
                    "تم التراجع عن إنشاء الوحدات: النتيجة لا تطابق قواعد المخزون المعرّف.",
                    detail={"violations": refusal.violations[:20]},
                )
            )
        return result

    def _build_units(self, result):
        """One article per collapsed row, then its provenance, then its history."""
        resolver = self.resolver
        now = timezone.now()
        taken = self._identifiers_already_in_stock()
        existing = self._existing_units()
        # (order, variant) -> the units that invoice took, so two identical
        # handsets on one invoice can be paired with its two lines.
        sold_on: dict = defaultdict(list)
        built: list = []
        for candidate in self.candidates.values():
            if normalize_identifier(candidate.identifier) in taken:
                # The plan was built before this handset was on the shelf, or
                # a second file claims it too. Refusing one article is a line
                # in the report; letting the unique index refuse it would take
                # the whole phase down with it.
                result.counts[SKIPPED] += 1
                result.issues.append(
                    Issue(
                        WARNING,
                        "collapse_identifier_in_stock",
                        f"المعرّف {candidate.identifier} موجود بالفعل في "
                        "المخزون؛ لم تُنشأ وحدة لهذا الصنف.",
                        source_key=candidate.source_key,
                    )
                )
                continue
            variant_pk = resolver.resolve(VARIANT, candidate.source_key)
            if variant_pk is None:
                result.counts[SKIPPED] += 1
                result.issues.append(
                    Issue(
                        WARNING,
                        "collapse_variant_missing",
                        "لم يُنشأ الصنف المقابل لهذه الوحدة؛ تم تخطيها.",
                        source_key=candidate.source_key,
                    )
                )
                continue
            self.variant_ids.add(variant_pk)
            unit, created = self._ensure_unit(
                candidate,
                existing=existing.get(candidate.source_key),
                variant_pk=variant_pk,
                supplier_pk=(
                    resolver.resolve(SUPPLIER, candidate.supplier_source_key)
                    if candidate.supplier_source_key
                    else None
                ),
                now=now,
            )
            result.counts[CREATED if created else UPDATED] += 1
            order_pk = (
                resolver.resolve(SALE, candidate.sale_source_key)
                if candidate.sale_source_key and candidate.is_sold
                else None
            )
            if order_pk is not None:
                sold_on[(order_pk, variant_pk)].append(unit)
            built.append((candidate, unit, order_pk))

        self._link_sales(sold_on)
        self._write_history(built)

    def _identifiers_already_in_stock(self) -> set:
        """Identifiers this shop is already holding under a different unit.

        Excludes the units this plan itself created on an earlier run — a
        re-import updates its own articles rather than colliding with them.
        """
        mine = set(
            self.resolver.resolve(COLLAPSE_UNIT, candidate.source_key)
            for candidate in self.candidates.values()
        )
        # Only the articles this plan says are still on the shelf: a sold one
        # frees its identifier by design, which is what lets a handset the shop
        # sold and bought back be two rows with one number.
        codes = [
            normalize_identifier(candidate.identifier)
            for candidate in self.candidates.values()
            if candidate.identifier and not candidate.is_sold
        ]
        taken: set = set()
        for batch in _chunks(codes):
            taken |= set(
                StockUnit.objects.filter(
                    code_normalized__in=batch,
                    status__in=StockUnit.LIVE_STATUSES,
                )
                .exclude(pk__in=[pk for pk in mine if pk])
                .values_list("code_normalized", flat=True)
            )
        return taken

    def _existing_units(self) -> dict:
        """``{source key: StockUnit}`` for everything an earlier run created.

        One query for the whole plan rather than one per article: a re-import
        of a thirty-thousand-handset catalogue is the case this feature has to
        survive, and ``resolver.existing`` is a query each.
        """
        mapped = {
            candidate.source_key: self.resolver.resolve(COLLAPSE_UNIT, candidate.source_key)
            for candidate in self.candidates.values()
        }
        wanted = [pk for pk in mapped.values() if pk]
        if not wanted:
            return {}
        units: dict = {}
        for batch in _chunks(wanted):
            units.update(StockUnit.objects.in_bulk(batch))
        return {source_key: units[pk] for source_key, pk in mapped.items() if pk in units}

    def _ensure_unit(self, candidate, *, existing, variant_pk, supplier_pk, now):
        resolver = self.resolver
        unit = existing
        created = unit is None
        status = StockUnit.Status.SOLD if candidate.is_sold else StockUnit.Status.IN_STOCK
        acquired_at = candidate.acquired_at or candidate.sold_at or now
        if unit is None:
            # Born with the status its history gives it. This is the one place a
            # unit's status is not a transition, because there is no earlier
            # state to transition from — the article's whole life happened in
            # somebody else's database.
            unit = StockUnit(
                variant_id=variant_pk,
                warehouse_id=self.warehouse_id,
                status=status,
            )
        elif unit.status != status:
            tracking.transition_unit(unit, status, save=False)
        unit.variant_id = variant_pk
        unit.warehouse_id = self.warehouse_id
        unit.code = candidate.identifier
        unit.identifier_kind = candidate.identifier_kind or unit.identifier_kind
        # The shop's own shelf label for this handset, so four years of printed
        # barcodes keep scanning and keep resolving to the right article.
        unit.secondary_code = _secondary_code(candidate)
        unit.is_identified = True
        unit.incoming_rate = candidate.unit_cost or ZERO
        unit.list_price = candidate.list_price
        unit.sold_price = candidate.sold_price if candidate.is_sold else None
        unit.supplier_id = supplier_pk
        unit.acquired_at = acquired_at
        unit.in_stock_since = acquired_at
        unit.sold_at = candidate.sold_at if candidate.is_sold else None
        unit.attributes = self._clean_attributes(candidate)
        unit.notes = candidate.source_name
        unit.save()
        resolver.remember(COLLAPSE_UNIT, candidate.source_key, unit)
        return unit, created

    def _clean_attributes(self, candidate) -> dict:
        """The article's own facts, in the shape every other writer stores.

        Through the same coercion a captured unit's attributes go through, so a
        migrated handset is indistinguishable from a scanned one: a percentage
        is a JSON number (``attributes->>'battery_health' >= 85`` compares as a
        number, not as the string "9" beating "85"), a grade is one of the
        definition's own values, and a key nothing defines is dropped.
        """
        values = dict(candidate.attributes or {})
        if not values or self.plan.asset_type_id is None:
            return values
        cleaned = {}
        for key, value in values.items():
            try:
                cleaned.update(
                    validate_attributes(
                        {key: value},
                        asset_type_id=self.plan.asset_type_id,
                        definitions=self._attribute_definitions(),
                        partial=True,
                    )
                )
            except ValidationError:
                # One unreadable fact is not worth the article it is about, and
                # not worth the four beside it either.
                continue
        return cleaned

    def _attribute_definitions(self):
        """The plan's asset type's definitions, read once for the whole run."""
        if self._definitions is None:
            self._definitions = definitions_for(self.plan.asset_type_id)
        return self._definitions

    def _link_sales(self, sold_on):
        """Point each sold article at the invoice line that took it.

        Two identical handsets on one invoice are two lines on one variant, and
        which article belongs to which line is genuinely arbitrary — same model,
        same price, same day. Pairing them in a fixed order keeps the assignment
        deterministic across re-runs, which is the part that matters.
        """
        if not sold_on:
            return
        from apps.sales.models import Order, OrderLine

        order_ids = sorted({order_pk for order_pk, _variant_pk in sold_on})
        variant_ids = sorted({variant_pk for _order_pk, variant_pk in sold_on})
        customers: dict = {}
        lines: dict = defaultdict(list)
        for batch in _chunks(order_ids):
            customers.update(
                dict(Order.objects.filter(pk__in=batch).values_list("pk", "customer_id"))
            )
            for row in (
                OrderLine.objects.filter(order_id__in=batch, variant_id__in=variant_ids)
                .order_by("id")
                .values("pk", "order_id", "variant_id")
            ):
                lines[(row["order_id"], row["variant_id"])].append(row["pk"])

        touched = []
        for key, units in sold_on.items():
            available = lines.get(key, [])
            for index, unit in enumerate(units):
                unit.sold_order_line_id = available[index] if index < len(available) else None
                unit.customer_id = customers.get(key[0])
                touched.append(unit)
        StockUnit.objects.bulk_update(
            touched,
            ["sold_order_line", "customer", "updated_at"],
            batch_size=CHUNK,
        )

    def _write_history(self, built):
        """One ``in`` allocation per article, and one ``out`` for every article
        that left.

        A unit with no history is a unit whose first sale looks like it left
        twice (invariant 6), and a sold unit whose last allocation received it
        is invariant 8 failing. Both are written here, at the dates the old
        system's own invoices carry.
        """
        if not built:
            return
        already: set = set()
        for batch in _chunks([unit.pk for _candidate, unit, _order in built]):
            already |= set(
                StockAllocation.objects.filter(unit_id__in=batch).values_list("unit_id", flat=True)
            )
        rows = []
        for candidate, unit, order_pk in built:
            if unit.pk in already:
                continue
            received_at = unit.acquired_at or timezone.now()
            rows.append(
                _allocation(
                    unit,
                    direction=StockAllocation.Direction.IN,
                    at=received_at,
                    voucher_type=StockLedgerEntry.VoucherType.OPENING,
                    note="ترحيل من النظام السابق",
                )
            )
            if not candidate.is_sold:
                continue
            # Never before it arrived: a unit's life is read in posting order,
            # and an undated sale of a dated purchase would otherwise sort in
            # front of the arrival it followed.
            issued_at = max(unit.sold_at or received_at, received_at)
            rows.append(
                _allocation(
                    unit,
                    direction=StockAllocation.Direction.OUT,
                    at=issued_at,
                    voucher_type=(
                        StockLedgerEntry.VoucherType.SALE
                        if order_pk
                        else StockLedgerEntry.VoucherType.OPENING
                    ),
                    voucher_id=order_pk,
                    note="بيع سابق" if order_pk else "خرج قبل الترحيل",
                )
            )
        StockAllocation.objects.bulk_create(rows, batch_size=500)

    def _open_the_shelf(self, result):
        """Put the surviving articles on the shelf, at what they cost.

        One opening ledger entry and one valuation bin per variant, whose
        allocations are exactly the articles still here. The sold ones keep
        their own history and contribute nothing: they are not an opening
        balance, they are a past.
        """
        from apps.core.models import ShopSettings

        method = ShopSettings.load().inventory_valuation_method
        at = timezone.now()
        on_hand = defaultdict(list)
        for unit in StockUnit.objects.filter(
            variant_id__in=self.variant_ids,
            warehouse_id=self.warehouse_id,
            status__in=StockUnit.ON_HAND_STATUSES,
        ).order_by("pk"):
            on_hand[unit.variant_id].append(unit)

        opened = 0
        for variant_id in sorted(self.variant_ids):
            units = on_hand.get(variant_id, [])
            quantity = Decimal(len(units))
            value = sum((unit.stock_value for unit in units), ZERO)
            rate = (value / quantity) if quantity else ZERO
            StockItem.objects.update_or_create(
                variant_id=variant_id,
                warehouse_id=self.warehouse_id,
                defaults={"quantity_on_hand": quantity, "quantity_committed": ZERO},
            )
            StockValuationBin.objects.update_or_create(
                variant_id=variant_id,
                warehouse_id=self.warehouse_id,
                defaults={
                    "quantity": quantity,
                    "valuation_rate": rate,
                    "stock_value": value,
                    "state": [[str(quantity), str(rate)]] if quantity else [],
                    "method": method,
                },
            )
            if not quantity:
                continue
            entry = StockLedgerEntry.objects.filter(
                variant_id=variant_id,
                warehouse_id=self.warehouse_id,
                voucher_type=StockLedgerEntry.VoucherType.OPENING,
                voucher_id=self.plan.pk,
            ).first()
            if entry is None:
                entry = StockLedgerEntry(
                    variant_id=variant_id,
                    warehouse_id=self.warehouse_id,
                    voucher_type=StockLedgerEntry.VoucherType.OPENING,
                    voucher_id=self.plan.pk,
                )
            entry.posting_at = at
            entry.quantity_change = quantity
            entry.valuation_rate = rate
            entry.value_change = value
            entry.balance_quantity = quantity
            entry.balance_value = value
            entry.state = [[str(quantity), str(rate)]]
            entry.method = method
            entry.note = "رصيد افتتاحي من الترحيل"
            entry.save()
            # The opening entry moved exactly these articles, so its allocations
            # are exactly their arrivals (invariant 5).
            for batch in _chunks([unit.pk for unit in units]):
                StockAllocation.objects.filter(
                    unit_id__in=batch,
                    direction=StockAllocation.Direction.IN,
                ).update(ledger_entry=entry, posting_at=at)
            opened += 1
        result.stats["variants_opened"] = opened
        result.stats["units_on_hand"] = sum(len(units) for units in on_hand.values())


class _InvariantsViolated(Exception):
    def __init__(self, violations):
        super().__init__("identified-stock invariants violated")
        self.violations = violations


# --- loader wrappers ---------------------------------------------------------


class _WrappedLoader(BaseLoader):
    def __init__(self, session, inner):
        self.session = session
        self.inner = inner
        self.entity_type = inner.entity_type


class _CollapsedProductLoader(_WrappedLoader):
    def load(self, record, resolver, *, dry_run):
        candidate = self.session.candidate_for(record.source_key)
        if candidate is None:
            return self.inner.load(record, resolver, dry_run=dry_run)
        return self.session.load_product(record, candidate, resolver)


class _CollapsedVariantLoader(_WrappedLoader):
    def load(self, record, resolver, *, dry_run):
        if self.session.candidate_for_variant(record.source_key) is None:
            return self.inner.load(record, resolver, dry_run=dry_run)
        # The product pass already created it and registered the key.
        return LoadOutcome(SKIPPED, None)


class _CollapsedStockLoader(_WrappedLoader):
    def load(self, record, resolver, *, dry_run):
        if self.session.candidate_for_variant(record.variant_source_key) is None:
            return self.inner.load(record, resolver, dry_run=dry_run)
        # The units are the count. Writing the old system's quantity here too
        # would give one number two authorities — see the module docstring.
        return LoadOutcome(SKIPPED, None)


# --- helpers -----------------------------------------------------------------


def _allocation(unit, *, direction, at, voucher_type, voucher_id=None, note=""):
    sign = ONE if direction == StockAllocation.Direction.IN else -ONE
    rate = Decimal(unit.incoming_rate or 0)
    return StockAllocation(
        unit=unit,
        variant_id=unit.variant_id,
        warehouse_id=unit.warehouse_id,
        direction=direction,
        quantity=ONE,
        rate=rate,
        value_change=sign * rate,
        voucher_type=voucher_type,
        voucher_id=voucher_id,
        posting_at=at,
        note=note,
    )


def _chunks(values, size=CHUNK):
    ordered = list(values)
    for start in range(0, len(ordered), size):
        yield ordered[start : start + size]


def _variant_identity(stem_key: str, signature: str) -> str:
    """A stable, bounded identity-map key for one collapsed variant.

    Readable at the front so a support engineer can see which product a row
    belongs to, and hashed at the back because ``stem_key`` alone can already
    fill the column — a key that silently truncated would make two variants of
    a long-named product the same row.
    """
    full = f"{stem_key}\u241f{signature}"
    digest = hashlib.sha1(full.encode("utf-8")).hexdigest()[:16]
    return f"{stem_key[:120]}#{digest}"


def _option_signature(options) -> str:
    return "|".join(f"{axis}={options[axis]}" for axis in OPTION_AXES if (options or {}).get(axis))


def _variant_name(options) -> str:
    return " / ".join(
        option_label(axis, options[axis]) for axis in OPTION_AXES if (options or {}).get(axis)
    )


def _variant_price(candidate) -> Decimal:
    for value in (candidate.list_price, candidate.sold_price):
        if value:
            return Decimal(value)
    return ZERO


def _has_default(product, variant) -> bool:
    return (
        ProductVariant.objects.filter(product=product, is_default=True)
        .exclude(pk=variant.pk)
        .exists()
    )


def _free_sku(product) -> str:
    base = f"P{product.pk:06d}"
    candidate = base
    suffix = 2
    while ProductVariant.objects.filter(sku=candidate).exists():
        candidate = f"{base}-{suffix}"
        suffix += 1
    return candidate


def _secondary_code(candidate) -> str:
    code = normalize_barcode(candidate.legacy_barcode or "")
    return "" if code == candidate.identifier else code[:120]


def _set_option_values(variant, options) -> None:
    """Attach the variant's options, reusing the registry rather than adding to it.

    Pointy already ships a ``storage`` option with the capacities a phone shop
    uses (``catalog/migrations/0006``), so the collapse's job is to *find* those
    rows, not to make second ones. Both lookups go through the model's own
    normalisation — codes are lowercased on save, so a lookup for ``256GB``
    misses the seeded ``256gb`` and then fails its own unique constraint on the
    way in.

    A colour option is usually the one thing missing, and a phone shop acquires
    it here already populated with the colours its own catalogue turned out to
    contain.

    The product's own schema is widened first: a variant may only select values
    of options its product declares, so attaching a value before declaring the
    option is refused by ``validate_variant_option_values`` — which is the right
    rule, and the collapse's job is to satisfy it rather than route around it.
    """
    chosen = []
    for order, axis in enumerate(OPTION_AXES):
        raw = (options or {}).get(axis)
        if not raw:
            continue
        option, _created = VariantOption.objects.get_or_create(
            code=axis.strip().lower(),
            defaults={"name": OPTION_LABELS.get(axis, axis), "display_order": order},
        )
        chosen.append((option, _option_value(option, axis, raw)))
    if chosen:
        variant.product.variant_options.add(*[option for option, _value in chosen])
    variant.option_values.set([value for _option, value in chosen])


def _option_value(option, axis, raw):
    """This option's row for ``raw``, by code and then by the name it would take.

    The second lookup is what stops a shop that already calls blue «أزرق» from
    getting a second «أزرق» — ``(option, name)`` is unique too, so creating one
    would fail rather than duplicate, and failing here would lose the whole
    product.
    """
    code = str(raw).strip().lower()[:64]
    name = option_label(axis, raw)[:160]
    existing = VariantOptionValue.objects.filter(option=option, code=code).first()
    if existing is not None:
        return existing
    existing = VariantOptionValue.objects.filter(option=option, name=name).first()
    if existing is not None:
        return existing
    return VariantOptionValue.objects.create(option=option, code=code, name=name)


__all__ = ["COLLAPSE_PRODUCT", "COLLAPSE_UNIT", "COLLAPSE_VARIANT", "CollapseSession"]
