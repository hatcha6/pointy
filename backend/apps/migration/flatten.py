"""Flatten imported alias variants into one variant with several barcodes.

Older imports turned every extra code a legacy system knew for an item into a
variant of its own. A shop that has traded on that shape for months has sales,
purchases, counts and stock spread across "variants" that were only ever other
barcodes of one thing. Since 2026-10-17 a new import files them as extra
barcodes (``ProductVariantBarcode``); this brings a shop already live on the old
shape to the same place, using nothing but its own database.

**Everything moves and nothing is invented.** Documents, ledger and movements
are repointed, so a return of an old sale, a product's sales history and the
purchase suggestions all read as if the code had been an extra barcode from the
start. Money and quantities on those rows are not touched: order totals, cost of
goods sold and the shop-wide on-hand are proved identical before each product
commits, or that product rolls back and is reported.

**It is not a trading event.** Profit, shrinkage and the balance sheet's result do
not move. The single figure that can is stock value, and only where an alias sold
below zero at a different cost than the shelf it really came from. The difference
goes on the ledger as ``CATALOG_MERGE``, which no profit figure reads, and the dry
run states the amount before anything is written.

The alias row stays as a **tombstone** (inactive, barcode-less,
``merged_into`` set). A till holding the old id in a cart still rings the
survivor, a count line that cannot be folded still has a row to name, and a run
that lost a race to a checkout can sweep the leftovers on its next pass.

Only what is provably an alias is taken automatically. Anything that would change
what the till charges or could lose a meaning goes to ``review`` with a reason:
a different price, a real option value, identified stock, an open count.
"""

from __future__ import annotations

import time
from collections import Counter
from dataclasses import dataclass, field
from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.db import OperationalError, connection, transaction
from django.db.models import Sum

from apps.catalog.cache import announce_bulk_catalog_write
from apps.catalog.models import (
    Product,
    ProductUnitBarcode,
    ProductVariant,
    ProductVariantBarcode,
    normalize_barcode,
)
from apps.inventory.models import (
    StockCount,
    StockCountLine,
    StockItem,
    StockLedgerEntry,
    StockValuationBin,
    Warehouse,
)
from apps.inventory.valuation import load_state, state_rows, valuation_engine
from apps.inventory.valuation_service import current_method

from .models import MigrationIdentityMap, VariantMerge

ZERO = Decimal("0")

#: Review reasons. The machine half of the report; the command prints them and a
#: person decides. Stable strings, because an operator passes them back.
PRICE_DIFFERS = "price_differs"
HAS_OPTIONS = "has_option_values"
NOT_IMPORTED = "not_imported"
IDENTIFIED_STOCK = "identified_stock"
OPEN_COUNT = "open_stock_count"
BARCODE_ELSEWHERE = "barcode_used_elsewhere"
LOT_CODE_CLASH = "lot_code_clash"
UNIQUE_ROW_CLASH = "unique_row_clash"
NO_SURVIVOR = "no_default_variant"

#: Reasons an owner may overrule with ``--include``. The rest would lose data.
OVERRULABLE = frozenset({PRICE_DIFFERS, NOT_IMPORTED})

#: Rollups rebuilt from the documents. A clash just drops the alias's row.
ROLLUPS = frozenset(
    {
        ("purchasing", "supplierpurchasehabit"),
        ("purchasing", "supplierpurchaseaffinity"),
    }
)
#: Rows with a uniqueness rule whose clash cannot be summed away. Moved when the
#: survivor has no such row; otherwise the product waits for a person.
UNIQUE_MOVES = frozenset(
    {
        ("catalog", "scaleplu"),
        ("catalog", "bomline"),
        ("integrations", "integrationvoucher"),
        ("integrations", "integrationpricerule"),
    }
)
#: Handled by hand below.
MERGED = frozenset(
    {
        ("inventory", "stockitem"),
        ("inventory", "stockvaluationbin"),
        ("inventory", "stockcountline"),
        ("inventory", "stockbatch"),
        ("catalog", "productvariantbarcode"),
        ("catalog", "productvariant"),
        ("migration", "variantmerge"),
    }
)


class FlattenRefused(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason
        self.detail = detail


@dataclass
class Candidate:
    product_id: int
    product_name: str
    survivor_id: int | None
    alias_id: int
    alias_sku: str
    alias_barcode: str
    alias_name: str
    alias_active: bool
    reasons: list = field(default_factory=list)
    detail: str = ""

    @property
    def automatic(self) -> bool:
        return not self.reasons


def variant_references():
    """Every concrete foreign key at a variant, including the hidden ones.

    Discovered rather than listed, so a table added next year is moved by
    default instead of being quietly left pointing at a tombstone.
    """
    refs = []
    for relation in ProductVariant._meta.get_fields(include_hidden=True):
        if relation.auto_created and not relation.concrete and relation.is_relation:
            source = relation.field
            # A many-to-many's hidden through table is moved through the manager.
            if (
                source.many_to_many
                or not source.concrete
                or source.model._meta.auto_created
            ):
                continue
            refs.append((source.model, source))
    return refs


def many_to_many_references():
    """``(owner model, field name, through table, alias column)`` at a variant."""
    refs = []
    for relation in ProductVariant._meta.related_objects:
        if relation.many_to_many:
            field = relation.field
            through = field.remote_field.through
            column = next(
                f.column
                for f in through._meta.concrete_fields
                if f.is_relation and f.related_model is ProductVariant
            )
            refs.append((relation.related_model, field.name, through._meta.db_table, column))
    return refs


def _label(model) -> str:
    return model._meta.label_lower


def held_references(alias_ids) -> dict:
    """``{alias id: {table label}}``: which tables hold a row for each alias.

    One statement instead of a query per table per alias. Most aliases in a real
    shop were never rung, and asking forty tables about each of them was nearly
    all the cost of a run. A sale that adds a reference just after this reads is
    what :func:`sweep_tombstones` is for.
    """
    ids = list(alias_ids)
    marks = ",".join(["%s"] * len(ids))
    quote = connection.ops.quote_name
    sources = [
        (_label(model), model._meta.db_table, fk.column)
        for model, fk in variant_references()
    ] + [
        (f"m2m:{_label(owner)}", table, column)
        for owner, _name, table, column in many_to_many_references()
    ]
    parts, params = [], []
    for label, table, column in sources:
        # The label is ours, from the model registry, never from a request.
        parts.append(
            f"SELECT DISTINCT {quote(column)}, '{label}' "
            f"FROM {quote(table)} WHERE {quote(column)} IN ({marks})"
        )
        params.extend(ids)
    held: dict = {alias_id: set() for alias_id in alias_ids}
    with connection.cursor() as cursor:
        cursor.execute(" UNION ALL ".join(parts), params)
        for alias_id, label in cursor.fetchall():
            # A self reference names the tombstones of this row, not its history.
            if label != "catalog.productvariant":
                held[alias_id].add(label)
    return held


def _imported_variant_ids() -> set:
    content_type = ContentType.objects.get_for_model(ProductVariant)
    return set(
        MigrationIdentityMap.objects.filter(
            target_content_type=content_type
        ).values_list("target_object_id", flat=True)
    )


def _barcodes_held_elsewhere(codes: set) -> dict:
    """``{code: owning product id}`` for every code some row of the catalog holds."""
    held: dict = {}
    if not codes:
        return held
    for code, product_id in ProductVariant.objects.filter(barcode__in=codes).values_list(
        "barcode", "product_id"
    ):
        held.setdefault(code, set()).add(product_id)
    for code, product_id in ProductVariantBarcode.objects.filter(
        barcode__in=codes
    ).values_list("barcode", "variant__product_id"):
        held.setdefault(code, set()).add(product_id)
    for code, product_id in ProductUnitBarcode.objects.filter(
        barcode__in=codes
    ).values_list("barcode", "product_unit__product_id"):
        held.setdefault(code, set()).add(product_id)
    return held


def scan_candidates() -> list[Candidate]:
    """Every non-default, unmerged variant, and whether it is safely an alias."""
    imported = _imported_variant_ids()
    aliases = list(
        ProductVariant.objects.filter(is_default=False, merged_into__isnull=True)
        .select_related("product")
        .prefetch_related("option_values")
        .order_by("product_id", "id")
    )
    if not aliases:
        return []
    product_ids = {variant.product_id for variant in aliases}
    survivors = {
        variant.product_id: variant
        for variant in ProductVariant.objects.filter(
            product_id__in=product_ids, is_default=True, merged_into__isnull=True
        )
    }
    held = _barcodes_held_elsewhere(
        {
            normalize_barcode(variant.barcode)
            for variant in aliases
            if normalize_barcode(variant.barcode)
        }
    )
    open_counts = set(
        StockCountLine.objects.exclude(
            stock_count__status__in=_closed_count_statuses()
        ).values_list("variant_id", flat=True)
    )

    candidates = []
    for alias in aliases:
        product = alias.product
        survivor = survivors.get(alias.product_id)
        code = normalize_barcode(alias.barcode)
        candidate = Candidate(
            product_id=alias.product_id,
            product_name=product.name,
            survivor_id=survivor.pk if survivor else None,
            alias_id=alias.pk,
            alias_sku=alias.sku,
            alias_barcode=code,
            alias_name=alias.name,
            alias_active=alias.is_active,
        )
        reasons = candidate.reasons
        if survivor is None:
            reasons.append(NO_SURVIVOR)
        if alias.option_values.all():
            reasons.append(HAS_OPTIONS)
        if alias.pk not in imported and not (code and code == alias.sku):
            # Neither the identity map nor the shape says "an import made this";
            # somebody may have built it on purpose.
            reasons.append(NOT_IMPORTED)
        if survivor is not None and alias.is_active:
            if alias.unit_price != survivor.unit_price:
                reasons.append(PRICE_DIFFERS)
                candidate.detail = f"{alias.unit_price} / {survivor.unit_price}"
        if product.tracking_mode in (
            Product.TrackingMode.SERIAL,
            Product.TrackingMode.SERIAL_BATCH,
        ):
            reasons.append(IDENTIFIED_STOCK)
        if alias.pk in open_counts or (survivor and survivor.pk in open_counts):
            reasons.append(OPEN_COUNT)
        if code and held.get(code, set()) - {alias.product_id}:
            reasons.append(BARCODE_ELSEWHERE)
        candidates.append(candidate)
    return candidates


def _closed_count_statuses():
    return (StockCount.Status.APPLIED, StockCount.Status.CANCELLED)


# ---------------------------------------------------------------------------
# What must not move
# ---------------------------------------------------------------------------


def product_fingerprint(product_id: int) -> dict:
    """What the shop would notice going missing, for one product.

    Stated in raw terms and read straight from the tables the merge touches, so
    it is not the merge agreeing with itself.
    """
    from apps.purchasing.models import PurchaseLine
    from apps.sales.models import OrderLine

    rows = StockItem.objects.filter(variant__product_id=product_id).aggregate(
        on_hand=Sum("quantity_on_hand"),
        committed=Sum("quantity_committed"),
        expected=Sum("quantity_expected"),
    )
    ledger = StockLedgerEntry.objects.filter(variant__product_id=product_id).aggregate(
        quantity=Sum("quantity_change"), value=Sum("value_change")
    )
    lines = OrderLine.objects.filter(variant__product_id=product_id)
    purchases = PurchaseLine.objects.filter(variant__product_id=product_id)
    return {
        "on_hand": rows["on_hand"] or ZERO,
        "committed": rows["committed"] or ZERO,
        "expected": rows["expected"] or ZERO,
        "ledger_quantity": ledger["quantity"] or ZERO,
        "ledger_value": ledger["value"] or ZERO,
        "order_lines": lines.count(),
        "order_quantity": lines.aggregate(total=Sum("quantity"))["total"] or ZERO,
        "purchase_lines": purchases.count(),
    }


# ---------------------------------------------------------------------------
# Merging one alias
# ---------------------------------------------------------------------------


def _merge_stock_items(alias, survivor) -> dict:
    """Fold the alias's stock rows into the survivor's. Returns on-hand by place."""
    moved = {}
    alias_rows = list(
        StockItem.objects.select_for_update(of=("self",))
        .filter(variant=alias)
        .order_by("warehouse_id")
    )
    for row in alias_rows:
        keeper, _ = StockItem.objects.select_for_update(of=("self",)).get_or_create(
            variant=survivor, warehouse_id=row.warehouse_id
        )
        keeper.quantity_on_hand += row.quantity_on_hand
        keeper.quantity_committed += row.quantity_committed
        keeper.quantity_expected += row.quantity_expected
        keeper.save(
            update_fields=[
                "quantity_on_hand",
                "quantity_committed",
                "quantity_expected",
                "updated_at",
            ]
        )
        # Before the delete: the movement's foreign key cascades.
        row.movements.update(stock_item=keeper, variant=survivor)
        moved[row.warehouse_id] = str(row.quantity_on_hand)
        row.delete()
    return moved


def _combined_engine(method, keeper_state, alias_state):
    """The survivor's valuation with the alias's shelf folded in. Pure."""
    alias_rows = load_state(alias_state) or []
    keeper_rows = load_state(keeper_state) or []
    if not keeper_rows:
        # Nothing of its own to combine with: the alias's state *is* the shelf.
        # Issuing a negative from an empty bin would lose its rate.
        return valuation_engine(method, alias_rows)
    engine = valuation_engine(method, keeper_rows)
    for quantity, rate in alias_rows:
        if Decimal(quantity) > ZERO:
            engine.add_stock(Decimal(quantity), Decimal(rate))
    for quantity, rate in alias_rows:
        if Decimal(quantity) < ZERO:
            engine.remove_stock(-Decimal(quantity), outgoing_rate=Decimal(rate))
    return engine


@dataclass
class ValueEstimate:
    """What a pass would do to valuation. Reads only, for the dry run."""

    #: How far the stock value line moves. Never profit (see ``CATALOG_MERGE``),
    #: but it is on the dashboard, so an owner hears the number first.
    value_restated: Decimal = ZERO
    #: Survivors whose combined cost would pass their selling price when their
    #: own had not: where a shop refuses sales at a loss, the till would start
    #: refusing them. ``[(variant id, price, cost before, cost after)]``.
    newly_below_cost: list = field(default_factory=list)


def estimate_valuation(candidates) -> ValueEstimate:
    """The same arithmetic a real merge does, folded in the same alias order."""
    survivor_of = {
        candidate.alias_id: candidate.survivor_id
        for candidate in candidates
        if candidate.survivor_id
    }
    result = ValueEstimate()
    if not survivor_of:
        return result
    method = current_method()
    states = {
        (row.variant_id, row.warehouse_id): row
        for row in StockValuationBin.objects.filter(
            variant_id__in={*survivor_of, *survivor_of.values()}
        )
    }
    running: dict = {}
    for (variant_id, warehouse_id), row in sorted(states.items()):
        survivor_id = survivor_of.get(variant_id)
        if survivor_id is None:
            continue
        key = (survivor_id, warehouse_id)
        keeper = states.get(key)
        keeper_state, keeper_value, keeper_method = (
            (keeper.state, Decimal(keeper.stock_value), keeper.method)
            if keeper is not None
            else ([], ZERO, method)
        )
        state, value, _rate = running.get(key, (keeper_state, keeper_value, None))
        engine = _combined_engine(keeper_method or method, state, row.state)
        _quantity, combined = engine.get_total_stock_and_value()
        # Stored at six places, so this rounds the way the column will.
        combined = Decimal(combined).quantize(Decimal("0.000001"))
        result.value_restated += combined - (value + Decimal(row.stock_value))
        running[key] = (state_rows(engine.state), combined, engine.valuation_rate)

    prices = dict(
        ProductVariant.objects.filter(pk__in={key[0] for key in running}).values_list(
            "pk", "unit_price"
        )
    )
    for (survivor_id, warehouse_id), (_state, _value, rate) in sorted(running.items()):
        price = prices.get(survivor_id)
        keeper = states.get((survivor_id, warehouse_id))
        before = Decimal(keeper.valuation_rate) if keeper is not None else ZERO
        if price and rate > price and before <= price:
            result.newly_below_cost.append(
                (survivor_id, str(price), str(before), str(round(rate, 6)))
            )
    return result


def _merge_valuation_bins(alias, survivor) -> Decimal:
    """Combine the bins through the valuation engine, never by hand.

    A plain ``value / quantity`` is wrong exactly when it matters: an alias at
    ``-4`` next to a survivor at ``5`` would price the one remaining piece at
    whatever the arithmetic leaves, and every later sale would inherit it. The
    alias's minus is goods that really came off the survivor's shelf, so it is
    issued from the survivor's bin; its plus is received into it. Where that
    leaves the value differing from the two bins' sum, a value-only ledger entry
    states the difference, so the ledger still adds up to the bin.
    """
    method = current_method()
    delta_total = ZERO
    for row in StockValuationBin.objects.select_for_update(of=("self",)).filter(
        variant=alias
    ):
        keeper, _ = StockValuationBin.objects.select_for_update(of=("self",)).get_or_create(
            variant=survivor,
            warehouse_id=row.warehouse_id,
            defaults={"method": method},
        )
        before_value = Decimal(keeper.stock_value) + Decimal(row.stock_value)
        engine = _combined_engine(
            keeper.method or method, keeper.state, row.state
        )
        quantity, value = engine.get_total_stock_and_value()
        keeper.quantity = quantity
        keeper.stock_value = value
        keeper.valuation_rate = engine.valuation_rate
        keeper.state = state_rows(engine.state)
        keeper.save(
            update_fields=["quantity", "stock_value", "valuation_rate", "state", "updated_at"]
        )
        delta = Decimal(keeper.stock_value) - before_value
        if delta:
            StockLedgerEntry.objects.create(
                variant=survivor,
                warehouse_id=row.warehouse_id,
                posting_at=_now(),
                quantity_change=ZERO,
                valuation_rate=keeper.valuation_rate,
                value_change=delta,
                balance_quantity=keeper.quantity,
                balance_value=keeper.stock_value,
                state=keeper.state,
                method=keeper.method,
                # Never ADJUSTMENT: that is shrinkage, and would read on the
                # dashboard and the profit report as money the shop lost or made.
                voucher_type=StockLedgerEntry.VoucherType.CATALOG_MERGE,
                voucher_id=alias.pk,
                note=f"دمج الصنف الفرعي {alias.sku}"[:240],
            )
            delta_total += delta
        row.delete()
    return delta_total


def _now():
    from django.utils import timezone

    return timezone.now()


def _merge_lots(alias, survivor):
    from apps.inventory.models import StockBatch

    lots = StockBatch.objects.filter(variant=alias)
    if not lots.exists():
        return
    taken = set(
        StockBatch.objects.filter(variant=survivor).values_list(
            "code_normalized", flat=True
        )
    )
    if any(lot.code_normalized in taken for lot in lots):
        raise FlattenRefused(LOT_CODE_CLASH)
    lots.update(variant=survivor)


def _move_unique_row(model, fk, alias, survivor):
    rows = model.objects.filter(**{fk.name: alias})
    if not rows.exists():
        return 0
    if model._meta.label_lower == "catalog.bomline":
        boms = set(rows.values_list("bom_id", flat=True))
        if model.objects.filter(component_variant=survivor, bom_id__in=boms).exists():
            raise FlattenRefused(UNIQUE_ROW_CLASH, model._meta.label)
    elif model._meta.label_lower == "integrations.integrationpricerule":
        accounts = set(rows.values_list("account_id", flat=True))
        if model.objects.filter(variant=survivor, account_id__in=accounts).exists():
            raise FlattenRefused(UNIQUE_ROW_CLASH, model._meta.label)
    elif model.objects.filter(**{fk.name: survivor}).exists():
        raise FlattenRefused(UNIQUE_ROW_CLASH, model._meta.label)
    return rows.update(**{fk.name: survivor})


def _move_rollup(model, fk, alias, survivor):
    """Move a rollup row, dropping it where the survivor already has one."""
    moved = 0
    unique_fields = next(
        (
            constraint.fields
            for constraint in model._meta.constraints
            if fk.name in getattr(constraint, "fields", ())
        ),
        (),
    )
    for row in model.objects.filter(**{fk.name: alias}):
        clash = {
            name: (survivor if name == fk.name else getattr(row, f"{name}_id"))
            for name in unique_fields
        }
        if clash and model.objects.filter(**clash).exclude(pk=row.pk).exists():
            row.delete()
            continue
        setattr(row, fk.name, survivor)
        row.save(update_fields=[fk.name])
        moved += 1
    return moved


def _move_count_lines(alias, survivor) -> int:
    """Lines of a finished count move unless the survivor was counted there too.

    A finished count that counted both keeps the alias's line on the tombstone:
    those were two separate figures on the day, and summing them would rewrite a
    document that was signed off. Nothing reads it as live stock.
    """
    moved = 0
    taken = set(
        StockCountLine.objects.filter(variant=survivor).values_list(
            "stock_count_id", "batch_id"
        )
    )
    for line in StockCountLine.objects.filter(variant=alias):
        if (line.stock_count_id, line.batch_id) in taken:
            continue
        line.variant = survivor
        line.save(update_fields=["variant", "updated_at"])
        moved += 1
    return moved


def _rewrite_running_balances(survivor, warehouse_ids) -> None:
    """Make the combined histories read as one running balance.

    The per-row deltas are what happened and stay as they are. Only the
    ``before``/``after`` snapshots, which each described a chain that no longer
    exists alone, are restated. The ledger's ``balance_*`` likewise.
    """
    if not warehouse_ids:
        return
    with connection.cursor() as cursor:
        for warehouse_id in sorted(warehouse_ids):
            cursor.execute(
                """
                UPDATE inventory_stockledgerentry AS target SET
                    balance_quantity = running.quantity,
                    balance_value = running.value
                FROM (
                    SELECT id,
                        sum(quantity_change) OVER w AS quantity,
                        sum(value_change) OVER w AS value
                    FROM inventory_stockledgerentry
                    WHERE variant_id = %s AND warehouse_id = %s
                    WINDOW w AS (ORDER BY posting_at, id)
                ) running
                WHERE target.id = running.id
                  AND (target.balance_quantity, target.balance_value)
                      IS DISTINCT FROM (running.quantity, running.value)
                """,
                [survivor.pk, warehouse_id],
            )
            cursor.execute(
                """
                UPDATE inventory_stockmovement AS target SET
                    on_hand_after = running.total - running.tail,
                    on_hand_before = running.total - running.tail - running.delta,
                    committed_after = running.committed_total - running.committed_tail,
                    committed_before = running.committed_total - running.committed_tail - running.committed_delta,
                    expected_after = running.expected_total - running.expected_tail,
                    expected_before = running.expected_total - running.expected_tail - running.expected_delta
                FROM (
                    SELECT m.id,
                        m.on_hand_after - m.on_hand_before AS delta,
                        m.committed_after - m.committed_before AS committed_delta,
                        m.expected_after - m.expected_before AS expected_delta,
                        COALESCE(sum(m.on_hand_after - m.on_hand_before) OVER later, 0) AS tail,
                        COALESCE(sum(m.committed_after - m.committed_before) OVER later, 0) AS committed_tail,
                        COALESCE(sum(m.expected_after - m.expected_before) OVER later, 0) AS expected_tail,
                        i.quantity_on_hand AS total,
                        i.quantity_committed AS committed_total,
                        i.quantity_expected AS expected_total
                    FROM inventory_stockmovement m
                    JOIN inventory_stockitem i ON i.id = m.stock_item_id
                    WHERE m.variant_id = %s AND m.warehouse_id = %s
                    WINDOW later AS (
                        ORDER BY m.created_at, m.id
                        ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
                    )
                ) running
                WHERE target.id = running.id
                  AND (target.on_hand_after, target.committed_after, target.expected_after)
                      IS DISTINCT FROM (
                          running.total - running.tail,
                          running.committed_total - running.committed_tail,
                          running.expected_total - running.expected_tail
                      )
                """,
                [survivor.pk, warehouse_id],
            )


def _move_barcodes(alias, survivor, *, has_extras) -> list:
    moved = []
    code = normalize_barcode(alias.barcode)
    primary = normalize_barcode(survivor.barcode)
    if code:
        # First: the constraint would refuse the same code on the survivor while
        # the alias still holds it.
        ProductVariant.objects.filter(pk=alias.pk).update(barcode="")
    if code and code != primary:
        if not primary:
            survivor.barcode = code
            survivor.save(update_fields=["barcode", "updated_at"])
            primary = code
        elif ProductUnitBarcode.objects.filter(barcode=code).exists():
            # The pack already answers to it: a unit barcode rings the pack.
            pass
        else:
            ProductVariantBarcode.objects.get_or_create(
                barcode=code, defaults={"variant": survivor}
            )
        moved.append(code)
    if not has_extras:
        return moved
    for extra in ProductVariantBarcode.objects.filter(variant=alias):
        if extra.barcode == primary:
            extra.delete()
            continue
        extra.variant = survivor
        extra.save(update_fields=["variant", "updated_at"])
        moved.append(extra.barcode)
    return moved


def merge_alias(alias, survivor, *, held, run_key="") -> VariantMerge:
    """Fold one alias into its survivor. The caller owns the transaction, and
    afterwards owes :func:`_rewrite_running_balances` and the identity map."""
    counts = Counter()
    moved_stock = {}
    value_delta = ZERO
    barcodes = _move_barcodes(
        alias, survivor, has_extras="catalog.productvariantbarcode" in held
    )
    if "inventory.stockbatch" in held:
        _merge_lots(alias, survivor)
    if "inventory.stockitem" in held:
        moved_stock = _merge_stock_items(alias, survivor)
    if "inventory.stockvaluationbin" in held:
        value_delta = _merge_valuation_bins(alias, survivor)
    if "inventory.stockcountline" in held:
        counts["stock_count_lines"] = _move_count_lines(alias, survivor)

    for model, fk in variant_references():
        label = _label(model)
        key = (model._meta.app_label, model._meta.model_name)
        if label not in held or key in MERGED:
            continue
        if key in UNIQUE_MOVES:
            counts[model._meta.label] += _move_unique_row(model, fk, alias, survivor)
        elif key in ROLLUPS:
            counts[model._meta.label] += _move_rollup(model, fk, alias, survivor)
        else:
            counts[model._meta.label] += model.objects.filter(**{fk.name: alias}).update(
                **{fk.name: survivor}
            )

    for owner, name, _table, _column in many_to_many_references():
        if f"m2m:{_label(owner)}" in held:
            for row in owner.objects.filter(**{name: alias}):
                manager = getattr(row, name)
                manager.add(survivor)
                manager.remove(alias)
                counts[owner._meta.label] += 1

    changed = []
    if survivor.low_stock_threshold is None and alias.low_stock_threshold is not None:
        survivor.low_stock_threshold = alias.low_stock_threshold
        changed.append("low_stock_threshold")
    if alias.expiry_reminder_date and (
        survivor.expiry_reminder_date is None
        or alias.expiry_reminder_date < survivor.expiry_reminder_date
    ):
        # The sooner date: the shelf they now share goes off then.
        survivor.expiry_reminder_date = alias.expiry_reminder_date
        changed.append("expiry_reminder_date")
    if changed:
        survivor.save(update_fields=[*changed, "updated_at"])

    record = VariantMerge.objects.create(
        run_key=run_key,
        alias=alias,
        survivor=survivor,
        alias_sku=alias.sku,
        alias_barcode=normalize_barcode(alias.barcode),
        alias_name=alias.name,
        alias_was_active=alias.is_active,
        alias_unit_price=alias.unit_price,
        moved_on_hand=moved_stock,
        value_delta=value_delta,
        rows_moved={key: value for key, value in counts.items() if value},
        barcodes_moved=barcodes,
    )
    alias.barcode = ""
    alias.is_active = False
    alias.is_default = False
    alias.merged_into = survivor
    alias.expiry_reminder_date = None
    alias.save(
        update_fields=[
            "barcode",
            "is_active",
            "is_default",
            "merged_into",
            "expiry_reminder_date",
            "updated_at",
        ]
    )
    return record


#: Tables that make a running balance worth restating.
_HISTORY = frozenset({"inventory.stockledgerentry", "inventory.stockmovement"})


def _finish_merges(aliases, survivor, held) -> None:
    """Once per product, however many aliases: restate balances, repoint the map.

    Run per alias, a product with fifty codes rewrote its whole history fifty
    times.
    """
    if any(held[alias.pk] & _HISTORY for alias in aliases):
        warehouse_ids = set(
            StockItem.objects.filter(variant=survivor).values_list(
                "warehouse_id", flat=True
            )
        )
        _rewrite_running_balances(survivor, warehouse_ids)
    MigrationIdentityMap.objects.filter(
        target_content_type=ContentType.objects.get_for_model(ProductVariant),
        target_object_id__in=[alias.pk for alias in aliases],
    ).update(target_object_id=survivor.pk)


@dataclass
class ProductOutcome:
    product_id: int
    product_name: str
    merged: int = 0
    refused: str = ""
    detail: str = ""


#: How long one product waits behind a sale before giving way and retrying. Well
#: under the 10 seconds a checkout's own lock cap allows: the shop comes first.
LOCK_TIMEOUT = "3s"
ATTEMPTS = 4
_RETRYABLE = frozenset({"proof_failed"})


def _take_merge_locks(product_id) -> dict:
    """Lock a product in the order a checkout does, and return its variants.

    A checkout takes stock rows, then valuation bins, each ascending by variant,
    and only then inserts rows that need a share lock on the variant. So the
    merge takes the same two in the same order, and locks the variants themselves
    ``FOR NO KEY UPDATE``, which a foreign-key check does not wait for: holding
    the variants ``FOR UPDATE`` first deadlocked against a till within seconds at
    real scale.
    """
    if connection.vendor == "postgresql":
        with connection.cursor() as cursor:
            cursor.execute(f"SET LOCAL lock_timeout = '{LOCK_TIMEOUT}'")
    list(
        StockItem.objects.select_for_update(of=("self",))
        .filter(variant__product_id=product_id)
        .order_by("variant_id", "warehouse_id")
        .values_list("pk", flat=True)
    )
    list(
        StockValuationBin.objects.select_for_update(of=("self",))
        .filter(variant__product_id=product_id)
        .order_by("variant_id", "warehouse_id")
        .values_list("pk", flat=True)
    )
    return {
        variant.pk: variant
        for variant in ProductVariant.objects.select_for_update(no_key=True)
        .filter(product_id=product_id)
        .order_by("pk")
    }


def _flatten_once(product_id, alias_ids, outcome, *, run_key=""):
    with transaction.atomic():
        variants = _take_merge_locks(product_id)
        survivor = next(
            (
                variant
                for variant in variants.values()
                if variant.is_default and variant.merged_into_id is None
            ),
            None,
        )
        if survivor is None:
            raise FlattenRefused(NO_SURVIVOR)
        aliases = [
            variants[alias_id]
            for alias_id in alias_ids
            if alias_id in variants and alias_id != survivor.pk
        ]
        if not aliases:
            return
        held = held_references([alias.pk for alias in aliases])
        # With nothing to move there is nothing to prove, and that is most
        # products: the fingerprint is what reads a busy product's history.
        moves_anything = any(held[alias.pk] for alias in aliases)
        before = product_fingerprint(product_id) if moves_anything else None
        merged = 0
        for alias in aliases:
            merge_alias(alias, survivor, held=held[alias.pk], run_key=run_key)
            merged += 1
        _finish_merges(aliases, survivor, held)
        if moves_anything:
            _prove_unchanged(before, product_fingerprint(product_id))
    outcome.merged = merged


def flatten_product(product_id, alias_ids, *, run_key="") -> ProductOutcome:
    """Merge these aliases of one product, all or none, proved or rolled back.

    A till wins any contest: on a lock timeout or deadlock this product rolls
    back and tries again a moment later, and is reported if it never gets a turn.
    Nothing has been written when that happens, so the next run simply takes it.
    """
    product = Product.objects.get(pk=product_id)
    outcome = ProductOutcome(product_id=product_id, product_name=product.name)
    for attempt in range(1, ATTEMPTS + 1):
        try:
            _flatten_once(product_id, alias_ids, outcome, run_key=run_key)
            return outcome
        except FlattenRefused as refused:
            outcome.refused, outcome.detail = refused.reason, refused.detail
            if refused.reason not in _RETRYABLE:
                return outcome
        except OperationalError as error:
            outcome.refused, outcome.detail = "busy", str(error)[:200]
        time.sleep(0.2 * attempt)
    return outcome


def _prove_unchanged(before, after):
    """Stock, sold and bought quantities and lines add up the same afterwards.

    ``ledger_value`` is deliberately compared after allowing for the value-only
    reconciling entry: that entry is the honest record of how far two bins'
    values differed from the combined bin, so it is the one figure allowed to
    move, and it is reported on the merge row.
    """
    for key, value in before.items():
        if key == "ledger_value":
            continue
        if value != after[key]:
            raise FlattenRefused("proof_failed", f"{key}: {value} -> {after[key]}")


def sweep_tombstones(*, run_key="") -> int:
    """Move anything that landed on a tombstone after its merge.

    A checkout already past validation when the merge committed can still post
    to the old id. Idempotent, so it runs at the start and the end of a pass.
    """
    swept = 0
    tombstones = ProductVariant.objects.filter(merged_into__isnull=False)
    with_rows = set(
        StockItem.objects.filter(variant__in=tombstones).values_list(
            "variant_id", flat=True
        )
    )
    from apps.sales.models import OrderLine

    with_rows |= set(
        OrderLine.objects.filter(variant__in=tombstones).values_list(
            "variant_id", flat=True
        )
    )
    for alias_id in sorted(with_rows):
        product_id = ProductVariant.objects.values_list("product_id", flat=True).get(
            pk=alias_id
        )
        for attempt in range(1, ATTEMPTS + 1):
            try:
                with transaction.atomic():
                    variants = _take_merge_locks(product_id)
                    alias = variants[alias_id]
                    survivor = variants[alias.merged_into_id]
                    held = held_references([alias.pk])
                    merge_alias(alias, survivor, held=held[alias.pk], run_key=run_key)
                    _finish_merges([alias], survivor, held)
                swept += 1
                break
            except OperationalError:
                # Left for the next pass if it never gets a turn: nothing is lost
                # by waiting, and a shop's sale must not fail for this.
                time.sleep(0.2 * attempt)
    return swept


@dataclass
class RunReport:
    merged_variants: int = 0
    merged_products: int = 0
    swept: int = 0
    refused: list = field(default_factory=list)
    review: list = field(default_factory=list)
    automatic: list = field(default_factory=list)
    before: dict = field(default_factory=dict)
    after: dict = field(default_factory=dict)
    value_restated: Decimal = ZERO
    newly_below_cost: list = field(default_factory=list)


def shop_totals() -> dict:
    """The shop-wide proof, before and after a whole pass."""
    from apps.purchasing.models import PurchaseLine
    from apps.sales.models import Order, OrderLine

    stock = StockItem.objects.aggregate(
        on_hand=Sum("quantity_on_hand"),
        committed=Sum("quantity_committed"),
        expected=Sum("quantity_expected"),
    )
    ledger = StockLedgerEntry.objects.aggregate(
        quantity=Sum("quantity_change"), value=Sum("value_change")
    )
    return {
        "on_hand": stock["on_hand"] or ZERO,
        "committed": stock["committed"] or ZERO,
        "expected": stock["expected"] or ZERO,
        "ledger_quantity": ledger["quantity"] or ZERO,
        "ledger_value": ledger["value"] or ZERO,
        "orders": Order.objects.count(),
        "orders_total": Order.objects.aggregate(total=Sum("total"))["total"] or ZERO,
        "order_lines": OrderLine.objects.count(),
        "order_quantity": OrderLine.objects.aggregate(total=Sum("quantity"))["total"]
        or ZERO,
        "purchase_lines": PurchaseLine.objects.count(),
        "warehouses": Warehouse.objects.count(),
    }


def run(*, apply=False, include_reasons=(), only_product_ids=None, run_key="") -> RunReport:
    """One pass over the catalogue. Without ``apply`` it writes nothing at all."""
    report = RunReport(before=shop_totals())
    include = set(include_reasons) & OVERRULABLE
    by_product: dict = {}
    for candidate in scan_candidates():
        if only_product_ids and candidate.product_id not in only_product_ids:
            continue
        blocking = [reason for reason in candidate.reasons if reason not in include]
        if blocking:
            report.review.append(candidate)
            continue
        report.automatic.append(candidate)
        by_product.setdefault(candidate.product_id, []).append(candidate.alias_id)

    if apply:
        report.swept += sweep_tombstones(run_key=run_key)
        for product_id, alias_ids in sorted(by_product.items()):
            outcome = flatten_product(product_id, alias_ids, run_key=run_key)
            if outcome.refused:
                report.refused.append(outcome)
            else:
                report.merged_variants += outcome.merged
                report.merged_products += 1 if outcome.merged else 0
        report.swept += sweep_tombstones(run_key=run_key)
        if report.merged_variants or report.swept:
            announce_catalog_change()
    report.after = shop_totals()
    if not apply:
        estimate = estimate_valuation(report.automatic)
        report.value_restated = estimate.value_restated
        report.newly_below_cost = estimate.newly_below_cost
    elif run_key:
        report.value_restated = VariantMerge.objects.filter(run_key=run_key).aggregate(
            total=Sum("value_delta")
        )["total"] or ZERO
    return report


def announce_catalog_change():
    """Tills drop their cached catalogue. ``update`` fires no ``post_save``."""
    with transaction.atomic():
        announce_bulk_catalog_write()


__all__ = [
    "Candidate",
    "FlattenRefused",
    "OVERRULABLE",
    "flatten_product",
    "estimate_valuation",
    "held_references",
    "merge_alias",
    "product_fingerprint",
    "run",
    "scan_candidates",
    "shop_totals",
    "sweep_tombstones",
    "variant_references",
]
