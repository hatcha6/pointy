"""Stock reconstruction — compute on-hand by netting the transaction history.

An alternative to importing the source's stored stock snapshot. Instead of
trusting the old system's running balance (``ITEMS_SUB.QTY`` and its equivalents),
this rebuilds each variant's on-hand from the documents themselves:

    on_hand = Σ(units ever received on purchases) − Σ(units ever sold)

It is the right choice when a shop's stored balances drifted — a corrupted
running total, a bad manual adjustment — but its purchase and sale invoices are
intact. It is **only as complete as that invoice trail**, though. Anything that
moved stock without a purchase or a sale is invisible to the math:

* an opening balance entered as a stock count (not a purchase invoice),
* a supplier return or a customer return,
* an inter-store transfer,
* an expiry / damage write-off (common in a pharmacy).

So the reconstructed number can drift. The clearest, most actionable symptom is a
variant that sold **more than it ever received**: the net goes negative, which is
physically impossible, and therefore *proves* the inbound history is incomplete
for that item. We clamp those to zero and raise a per-product warning the
operator can take straight back to the client ("the old system has no purchase /
opening stock for these items"), plus one headline summarising the damage.

Quantities net in the variant's **base unit**: the canonical sale/purchase line
``quantity`` is already base-unit (the same contract the order/PO loaders rely
on), so a box-of-12 purchase and single-unit sales net correctly *provided the
connector emits base-unit line quantities* — which is the IR contract.

**Snapshot comparison.** When the source also exposes a stock table, the engine
reads the old system's *stored* on-hand and feeds it here (without importing it).
``flush`` then reports, per product and in aggregate, how far that stored number
was from what the invoices imply — which is a goldmine of client-facing hints:

* ``stored > reconstructed`` → the surplus is most likely an **opening balance**
  the shop counted in but never recorded as a purchase (so reconstruction
  understates it). A lot of these ⇒ snapshot mode or a physical count is better.
* ``stored < reconstructed`` → the invoices say more should be on hand than the
  old system carries ⇒ **unrecorded outflows** (expiry, damage, returns, manual
  corrections).
* a stored balance with **no invoices at all** ⇒ the clearest proof the old
  system's movement history is incomplete for that item.
* the **match rate** (products where the two agree) is a single confidence number
  for how trustworthy the old system's quantities were in the first place.
* a **money view**: the reconstructed stock valued at each item's last purchase
  cost vs the same costing of the stored quantities ("worth X vs Y") — turning
  the discrepancy into a figure in the shop's currency.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

from django.db import transaction

from apps.catalog.models import ProductVariant
from apps.inventory.models import StockItem

from .entity_plan import PURCHASE_ORDER, SALE, VARIANT
from .loaders.base import (
    CREATED,
    ERROR,
    FAILED,
    SKIPPED,
    UPDATED,
    WARNING,
    Issue,
    to_decimal,
)

# Run-option ``stock_source`` values (also accepted as the legacy
# ``products_without_quantities`` boolean → ``none``).
STOCK_SOURCE_SNAPSHOT = "snapshot"  # copy the old system's stored quantities
STOCK_SOURCE_RECONSTRUCT = "reconstruct"  # compute from purchases − sales
STOCK_SOURCE_NONE = "none"  # import products with no quantities
VALID_STOCK_SOURCES = frozenset(
    {STOCK_SOURCE_SNAPSHOT, STOCK_SOURCE_RECONSTRUCT, STOCK_SOURCE_NONE}
)

# A reconstructed quantity within this of the stored snapshot counts as a match
# (guards against fractional-unit noise; base-unit quantities are usually whole).
_MATCH_TOLERANCE = Decimal("0.001")
# Cap per-product issues of each kind so a shop where *everything* diverges can't
# bury the headline summaries (the aggregate stats still carry the true totals).
# Issues are sorted by magnitude first, so the biggest discrepancies survive.
_MAX_ISSUES_PER_KIND = 400


def resolve_stock_source(options) -> str:
    """The effective stock source for a run's options (back-compat aware)."""
    options = options or {}
    raw = options.get("stock_source")
    if raw in VALID_STOCK_SOURCES:
        return raw
    # Legacy boolean toggle, predating the three-way stock-source selector.
    if options.get("products_without_quantities"):
        return STOCK_SOURCE_NONE
    return STOCK_SOURCE_SNAPSHOT


def _fmt(value: Decimal) -> str:
    """A short, human quantity: 8 not 8.000, 2.5 not 2.500, 0 not 0E-3."""
    value = Decimal(value)
    if value == value.to_integral_value():
        return str(value.to_integral_value())
    return format(value.normalize(), "f")


def _rate(part: int, whole: int) -> int:
    """``part`` as a whole-number percentage of ``whole`` (0 when ``whole`` is 0)."""
    return int(round(part * 100 / whole)) if whole else 0


def _top(records: list, limit: int) -> list:
    """The ``limit`` most significant issues from ``(magnitude, Issue)`` records."""
    records.sort(key=lambda item: item[0], reverse=True)
    return [issue for _magnitude, issue in records[:limit]]


def _money(value: Decimal) -> str:
    """A money figure with two decimals (the shop's currency is implicit)."""
    return str(Decimal(value).quantize(Decimal("0.01")))


@dataclass
class ReconstructionResult:
    #: Per-action counts for the run summary (created/updated/skipped/failed).
    counts: dict
    #: Warning issues to persist (per-product negatives + headlines).
    issues: list = field(default_factory=list)
    #: Structured stats stored under ``summary['stock']['reconstruction']``.
    stats: dict = field(default_factory=dict)


class StockReconstructor:
    """Accumulates purchase/sale movements per variant, then writes on-hand.

    Fed one canonical sale or purchase record at a time via :meth:`observe`
    during the engine's normal load pass (so the source is read once), then
    :meth:`flush` nets them, writes the ``StockItem`` rows, and returns
    diagnostics. Re-runs recompute from scratch and *set* on-hand (never
    increment), so the result is idempotent like the snapshot loader.
    """

    def __init__(self, resolver):
        self._resolver = resolver
        self._inflow: dict[int, Decimal] = {}
        self._outflow: dict[int, Decimal] = {}
        # Source lines we could not attribute to a known variant (e.g. a sale of
        # a product that was filtered out). Counted for an honest summary.
        self._unresolved_lines = 0
        # The old system's stored on-hand per variant (read but NOT imported in
        # reconstruct mode) — lets flush() report how far it was from invoices.
        self._snapshot: dict[int, Decimal] = {}
        self._has_snapshot = False
        # Most-recent purchase unit cost per variant, for valuation:
        # variant pk -> (occurred_at | None, unit_cost).
        self._cost: dict[int, tuple] = {}

    # --- accumulation ----------------------------------------------------
    def observe(self, entity_type: str, record) -> None:
        """Fold one sale (out) or purchase (in) record into the running totals."""
        if entity_type == PURCHASE_ORDER:
            bucket, is_purchase = self._inflow, True
        elif entity_type == SALE:
            bucket, is_purchase = self._outflow, False
        else:
            return
        occurred_at = getattr(record, "occurred_at", None)
        for line in getattr(record, "lines", None) or []:
            variant_pk = self._resolver.resolve(VARIANT, line.variant_source_key)
            if variant_pk is None:
                self._unresolved_lines += 1
                continue
            quantity = to_decimal(getattr(line, "quantity", 0))
            if quantity <= 0:
                continue
            bucket[variant_pk] = bucket.get(variant_pk, Decimal("0")) + quantity
            if is_purchase:
                self._consider_cost(variant_pk, occurred_at, to_decimal(getattr(line, "unit_cost", 0)))

    def _consider_cost(self, variant_pk, occurred_at, cost) -> None:
        """Keep the unit cost of the most recent purchase (for valuation).

        Prefers the latest dated purchase; a dated one beats an undated one, and
        between undated/equal-dated purchases the last seen wins.
        """
        if cost <= 0:
            return
        previous = self._cost.get(variant_pk)
        if previous is None:
            self._cost[variant_pk] = (occurred_at, cost)
            return
        prev_date, _prev_cost = previous
        if occurred_at is None:
            if prev_date is None:
                self._cost[variant_pk] = (occurred_at, cost)
        elif prev_date is None or occurred_at >= prev_date:
            self._cost[variant_pk] = (occurred_at, cost)

    def observe_snapshot(self, record, resolver) -> None:
        """Remember the old system's stored on-hand for a variant (read-only).

        Fed from the source's stock table in reconstruct mode so :meth:`flush`
        can report, per product, how far that stored number was from what the
        invoices imply — without importing it into Pointy.
        """
        variant_pk = resolver.resolve(VARIANT, getattr(record, "variant_source_key", ""))
        if variant_pk is None:
            return
        self._snapshot[variant_pk] = to_decimal(getattr(record, "quantity_on_hand", 0))
        self._has_snapshot = True

    # --- write + diagnose ------------------------------------------------
    def flush(self, *, dry_run: bool) -> ReconstructionResult:
        counts = {CREATED: 0, UPDATED: 0, SKIPPED: 0, FAILED: 0}
        transacted = set(self._inflow) | set(self._outflow)
        # Snapshot-only variants (stock in the old system, but no invoices) still
        # need evaluating — that's the clearest "missing history" signal.
        all_pks = transacted | set(self._snapshot)
        stats = {
            "products_evaluated": len(transacted),
            "products_set": 0,
            "products_zeroed": 0,
            "sold_without_purchase": 0,
            "total_deficit_units": "0",
            "unresolved_lines": self._unresolved_lines,
            "snapshot_available": self._has_snapshot,
        }
        if not all_pks:
            return ReconstructionResult(counts, [], stats)

        # One query resolves every variant's display info + stock-tracking flags.
        variants = {
            variant.pk: variant
            for variant in ProductVariant.objects.select_related("product").filter(
                pk__in=all_pks
            )
        }

        total_deficit = Decimal("0")
        # Snapshot-comparison accumulators.
        compared = matching = old_higher = old_lower = snapshot_only = 0
        total_implied_opening = Decimal("0")
        total_shrinkage = Decimal("0")
        # Valuation accumulators (both quantities valued at the same last cost).
        recon_value = Decimal("0")
        snap_value = Decimal("0")
        products_without_cost = 0
        # Issue buckets, kept apart so headlines + errors always beat per-product
        # noise to the (capped) issue table; the two _records lists are truncated
        # to the biggest discrepancies.
        error_issues: list[Issue] = []
        negative_records: list[tuple] = []
        mismatch_records: list[tuple] = []

        for variant_pk in all_pks:
            variant = variants.get(variant_pk)
            if variant is None:
                # The resolver gave us this pk, so the row should exist; guard
                # anyway (it may have been deleted mid-run) rather than crash.
                counts[FAILED] += 1
                continue

            product = variant.product
            # Service / made-to-order products don't hold stock — mirror the
            # snapshot stock loader and skip them.
            if product.is_service or product.is_prepared:
                counts[SKIPPED] += 1
                continue

            purchased = self._inflow.get(variant_pk, Decimal("0"))
            sold = self._outflow.get(variant_pk, Decimal("0"))
            has_tx = variant_pk in self._inflow or variant_pk in self._outflow
            net = purchased - sold
            reconstructed = net if net > 0 else Decimal("0")
            is_broken = has_tx and net < 0  # sold more than ever received
            name = product.name or variant.sku or f"#{variant_pk}"

            if has_tx:
                if is_broken:
                    deficit = -net
                    total_deficit += deficit
                    stats["products_zeroed"] += 1
                    negative_records.append(
                        (deficit, self._negative_issue(variant, name, purchased, sold, deficit, stats))
                    )
                else:
                    stats["products_set"] += 1
                try:
                    # Per-variant savepoint mirrors the engine's continue-on-error
                    # loop: one bad write fails alone instead of aborting the batch
                    # (and, in a dry run, without poisoning the outer transaction).
                    with transaction.atomic():
                        _stock_item, created = StockItem.objects.update_or_create(
                            variant_id=variant_pk,
                            defaults={"quantity_on_hand": reconstructed},
                        )
                except Exception as exc:  # noqa: BLE001 - record it and keep going
                    counts[FAILED] += 1
                    error_issues.append(
                        Issue(
                            ERROR,
                            "stock_write_failed",
                            f"تعذّر حفظ كمية الصنف ‘{name}’: {exc}"[:240],
                            source_key=variant.sku or str(variant.pk),
                        )
                    )
                    continue
                counts[CREATED if created else UPDATED] += 1

            # Compare against the old system's stored number. Broken (negative)
            # products are excluded from the confidence metric — their
            # reconstruction is known-unreliable and already reported above.
            if self._has_snapshot and variant_pk in self._snapshot and not is_broken:
                snap = self._snapshot[variant_pk]
                divergence = snap - reconstructed  # > 0 ⇒ old system claims more
                compared += 1
                if abs(divergence) < _MATCH_TOLERANCE:
                    matching += 1
                elif divergence > 0:
                    old_higher += 1
                    total_implied_opening += divergence
                    if not has_tx and snap > 0:
                        snapshot_only += 1
                    mismatch_records.append(
                        (divergence, self._mismatch_issue(variant, name, snap, reconstructed, divergence, has_tx))
                    )
                else:
                    old_lower += 1
                    total_shrinkage += -divergence
                    mismatch_records.append(
                        (-divergence, self._mismatch_issue(variant, name, snap, reconstructed, divergence, has_tx))
                    )

            # Money view: value the reconstructed and the stored quantity at the
            # SAME (last purchase) cost, so the gap reflects only the quantity
            # discrepancy. Products we never saw purchased have no cost basis.
            cost_entry = self._cost.get(variant_pk)
            snap_qty = self._snapshot.get(variant_pk, Decimal("0")) if self._has_snapshot else Decimal("0")
            if cost_entry is not None:
                cost = cost_entry[1]
                recon_value += reconstructed * cost
                snap_value += snap_qty * cost
            elif reconstructed > 0 or snap_qty > 0:
                products_without_cost += 1

        stats["total_deficit_units"] = _fmt(total_deficit)
        stats["reconstructed_inventory_value"] = _money(recon_value)
        if self._has_snapshot:
            stats.update(
                {
                    "snapshot_compared": compared,
                    "snapshot_matching": matching,
                    "snapshot_match_rate": _rate(matching, compared),
                    "old_system_higher": old_higher,
                    "old_system_lower": old_lower,
                    "total_implied_opening_units": _fmt(total_implied_opening),
                    "total_unexplained_shrinkage_units": _fmt(total_shrinkage),
                    "snapshot_only_no_history": snapshot_only,
                    "snapshot_inventory_value": _money(snap_value),
                    "inventory_value_difference": _money(recon_value - snap_value),
                    "products_without_cost": products_without_cost,
                }
            )

        issues = self._headline_issues(stats, total_deficit)
        issues += error_issues
        issues += _top(negative_records, _MAX_ISSUES_PER_KIND)
        issues += _top(mismatch_records, _MAX_ISSUES_PER_KIND)
        return ReconstructionResult(counts, issues, stats)

    # --- diagnostics -----------------------------------------------------
    def _negative_issue(self, variant, name, purchased, sold, deficit, stats) -> Issue:
        """A per-product warning, phrased for the operator to relay to the client."""
        detail = {
            "product": name,
            "sku": variant.sku,
            "purchased": _fmt(purchased),
            "sold": _fmt(sold),
            "deficit": _fmt(deficit),
        }
        if purchased <= 0:
            stats["sold_without_purchase"] += 1
            message = (
                f"الصنف ‘{name}’: تُوجد مبيعات بمقدار {_fmt(sold)} وحدة دون أي فاتورة "
                f"شراء في النظام القديم، فلا يمكن احتساب رصيد صحيح له. تم ضبط الرصيد "
                f"على صفر."
            )
            return Issue(
                WARNING, "sold_without_purchase", message,
                source_key=variant.sku or str(variant.pk), detail=detail,
            )
        message = (
            f"الصنف ‘{name}’: تم بيع {_fmt(sold)} وحدة بينما لم يُورَّد سوى "
            f"{_fmt(purchased)}، أي أن {_fmt(deficit)} وحدة خرجت دون أن تدخل. تم ضبط "
            f"الرصيد على صفر — غالبًا لأن النظام القديم يفتقد رصيدًا افتتاحيًا أو "
            f"فاتورة شراء أو تسوية مخزون لهذا الصنف."
        )
        return Issue(
            WARNING, "negative_stock", message,
            source_key=variant.sku or str(variant.pk), detail=detail,
        )

    def _mismatch_issue(self, variant, name, snap, reconstructed, divergence, has_tx) -> Issue:
        """A per-product "the old system said X, the invoices say Y" warning."""
        detail = {
            "product": name,
            "sku": variant.sku,
            "old_system": _fmt(snap),
            "reconstructed": _fmt(reconstructed),
            "difference": _fmt(abs(divergence)),
        }
        source_key = variant.sku or str(variant.pk)
        if divergence > 0 and not has_tx:
            message = (
                f"الصنف ‘{name}’: النظام القديم يسجّل رصيدًا قدره {_fmt(snap)} لكن لا "
                f"توجد له أي فاتورة شراء أو بيع، فاحتُسبت كميته صفرًا. هذا أوضح دليل "
                f"على أن حركات هذا الصنف غير مسجَّلة في النظام القديم."
            )
            return Issue(WARNING, "snapshot_without_history", message, source_key=source_key, detail=detail)
        if divergence > 0:
            message = (
                f"الصنف ‘{name}’: النظام القديم يسجّل {_fmt(snap)} بينما تُعطي الفواتير "
                f"{_fmt(reconstructed)} (أعلى بمقدار {_fmt(divergence)}). يُرجَّح أن "
                f"الفارق رصيد افتتاحي لم يُسجَّل كفاتورة شراء."
            )
            return Issue(WARNING, "quantity_higher_in_old_system", message, source_key=source_key, detail=detail)
        message = (
            f"الصنف ‘{name}’: النظام القديم يسجّل {_fmt(snap)} بينما تُعطي الفواتير "
            f"{_fmt(reconstructed)} (أقل بمقدار {_fmt(-divergence)}). تجاوُز الفواتير "
            f"للرصيد المسجَّل يشير إلى خروج لم يُوثَّق بفاتورة (تلف/إرجاع/تسوية مخزون)."
        )
        return Issue(WARNING, "quantity_lower_in_old_system", message, source_key=source_key, detail=detail)

    def _headline_issues(self, stats, total_deficit) -> list[Issue]:
        """The run-level warnings the operator sees front-and-centre."""
        out: list[Issue] = []
        zeroed = stats["products_zeroed"]
        if zeroed:
            out.append(
                Issue(
                    WARNING,
                    "reconstruction_incomplete_history",
                    (
                        f"احتُسبت الكميات من الفواتير: {zeroed} صنفًا خرج بكمية أكبر "
                        f"مما دخل (بإجمالي {_fmt(total_deficit)} وحدة) فتم ضبطها على "
                        f"صفر. هذا يدل على أن سجل المشتريات في النظام القديم غير مكتمل "
                        f"لهذه الأصناف (رصيد افتتاحي أو فواتير شراء مفقودة). راجع "
                        f"قائمتها قبل اعتماد الكميات، أو أجرِ جردًا فعليًا لها."
                    ),
                    detail=dict(stats),
                )
            )

        # Snapshot comparison: the headline number the operator shows the client.
        if stats.get("snapshot_available") and stats.get("snapshot_compared"):
            compared = stats["snapshot_compared"]
            rate = stats["snapshot_match_rate"]
            higher = stats["old_system_higher"]
            lower = stats["old_system_lower"]
            message = (
                f"مقارنة الكميات المحتسبة بأرقام النظام القديم: تطابقت في "
                f"{stats['snapshot_matching']} من {compared} صنفًا ({rate}%). "
                f"{higher} صنفًا سجّلها النظام القديم أعلى مما تُثبته الفواتير "
                f"(بمجموع {stats['total_implied_opening_units']} وحدة، يُرجَّح أنها "
                f"رصيد افتتاحي غير مُفوتَر)، و{lower} صنفًا أقل (بمجموع "
                f"{stats['total_unexplained_shrinkage_units']} وحدة، خروج غير موثَّق)."
            )
            # Turn the numbers into a recommendation about which mode fits.
            if higher and higher >= max(3, compared // 4):
                message += (
                    " بما أن أرقام النظام القديم تفوق فواتيره في كثير من الأصناف، فقد "
                    "يكون «نقل الكميات كما هي» أو الجرد الفعلي أدقّ من الاحتساب لهذا المتجر."
                )
            elif rate >= 90:
                message += " التطابق مرتفع، فالاحتساب من الفواتير موثوق لهذا المتجر."
            out.append(
                Issue(
                    WARNING,
                    "snapshot_comparison",
                    message,
                    detail={
                        key: stats[key]
                        for key in (
                            "snapshot_compared",
                            "snapshot_matching",
                            "snapshot_match_rate",
                            "old_system_higher",
                            "old_system_lower",
                            "total_implied_opening_units",
                            "total_unexplained_shrinkage_units",
                            "snapshot_only_no_history",
                        )
                    },
                )
            )
            if stats.get("snapshot_only_no_history"):
                out.append(
                    Issue(
                        WARNING,
                        "snapshot_only_no_history",
                        (
                            f"{stats['snapshot_only_no_history']} صنفًا له رصيد في النظام "
                            f"القديم دون أي فاتورة شراء أو بيع، فاحتُسبت كميته صفرًا. إن "
                            f"كان لدى المتجر مخزون فعلي لهذه الأصناف فالأنسب «نقل الكميات "
                            f"كما هي» أو إجراء جرد فعلي."
                        ),
                        detail={"snapshot_only_no_history": stats["snapshot_only_no_history"]},
                    )
                )

        # Money view: reconstructed inventory value vs the old system's, costed
        # identically so the gap is purely the quantity discrepancy in currency.
        if stats.get("snapshot_available") and "snapshot_inventory_value" in stats:
            recon_v = Decimal(stats["reconstructed_inventory_value"])
            snap_v = Decimal(stats["snapshot_inventory_value"])
            if recon_v or snap_v:
                message = (
                    f"تقييم المخزون بسعر آخر شراء: الكميات المحتسبة من الفواتير تساوي "
                    f"{stats['reconstructed_inventory_value']}، بينما الكميات المسجَّلة في "
                    f"النظام القديم تساوي {stats['snapshot_inventory_value']}."
                )
                diff = recon_v - snap_v
                if diff < 0:
                    message += f" النظام القديم يُظهر قيمة مخزون أعلى بمقدار {_money(-diff)}."
                elif diff > 0:
                    message += f" الفواتير تُظهر قيمة مخزون أعلى بمقدار {_money(diff)}."
                if stats.get("products_without_cost"):
                    message += (
                        f" ({stats['products_without_cost']} صنفًا بلا سعر شراء معروف لم "
                        f"يدخل في التقييم.)"
                    )
                out.append(
                    Issue(
                        WARNING,
                        "inventory_valuation",
                        message,
                        detail={
                            key: stats[key]
                            for key in (
                                "reconstructed_inventory_value",
                                "snapshot_inventory_value",
                                "inventory_value_difference",
                                "products_without_cost",
                            )
                        },
                    )
                )

        if self._unresolved_lines:
            out.append(
                Issue(
                    WARNING,
                    "reconstruction_unresolved_lines",
                    (
                        f"{self._unresolved_lines} سطرًا في فواتير الشراء/البيع يشير "
                        f"إلى منتج لم يُستورد، فلم يُحتسب ضمن الكميات."
                    ),
                    detail={"unresolved_lines": self._unresolved_lines},
                )
            )
        return out
