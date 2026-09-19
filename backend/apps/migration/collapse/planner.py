"""Building the proposal: read the catalogue, cluster it, price it, count it.

The half of §12 that happens before anybody agrees to anything. It reads the
prepared file the same way an import would — through the connector, never
through a vendor driver — and writes a :class:`~apps.migration.models.CollapsePlan`
whose candidate rows are the whole of the argument: *this* legacy product
becomes *this* unit of *that* product, and here is how sure we are.

Three things it does that a name parser alone cannot.

**It checks the premise.** §1.1's observation is that each of those products is
"bought exactly once and sold exactly once". That is a *testable* claim, and a
row that fails it — two on the shelf, sold three times — is not a handset with a
number in its name; it is an ordinary product that happens to contain digits.
Those keep their shape, and the reason is on the row.

**It prices from history, not from a guess.** Cost is what the shop paid on that
product's one purchase, the price is what it fetched on its one sale, and the
dates are the invoice dates. A migration that invented a cost would make every
past sale's margin fiction.

**It counts.** The screen this feeds says "340 products → 12 products, 31
variants, 340 units", and that sentence is the demo (§12). It is computed from
the candidate rows every time one is edited, so it can never be a memory of an
earlier answer.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from apps.inventory.identity import IdentifierKind

from ..connectors import get_connector
from ..connectors.base import ExtractContext
from ..entity_plan import PRODUCT, PURCHASE_ORDER, SALE, STOCK, VARIANT
from ..exceptions import MigrationError
from ..models import CollapseCandidate, CollapsePlan
from ..preparation.stages import Stage, StageTracker
from ..transports import build_transport
from .extract import (
    LOW_CONFIDENCE,
    Extraction,
    extract_name,
    option_label as parsing_option_label,
)

ZERO = Decimal("0")

READ_CATALOGUE = "catalogue"
READ_HISTORY = "history"
CLUSTER = "cluster"
PROPOSE = "propose"

BUILD_STAGES = (
    Stage(READ_CATALOGUE, "قراءة الأصناف"),
    Stage(READ_HISTORY, "قراءة الشراء والبيع"),
    Stage(CLUSTER, "تجميع الأصناف المتشابهة"),
    Stage(PROPOSE, "تجهيز الاقتراح"),
)

#: A cluster this size or smaller is still collapsed — the identifier becomes
#: scannable either way — but it is flagged, because "one product became one
#: product" is exactly what a mis-read stem looks like.
SINGLETON = 1


@dataclass
class _Evidence:
    """What the source's own documents say happened to one legacy product."""

    purchased_quantity: Decimal = ZERO
    sold_quantity: Decimal = ZERO
    unit_cost: Decimal = ZERO
    sold_price: Decimal | None = None
    acquired_at: object = None
    sold_at: object = None
    supplier_source_key: str = ""
    sale_source_key: str = ""
    stock_quantity: Decimal | None = None


@dataclass
class _Candidate:
    source_key: str
    source_name: str
    variant_source_key: str
    extraction: Extraction
    list_price: Decimal | None = None
    legacy_barcode: str = ""
    evidence: _Evidence = field(default_factory=_Evidence)
    decision: str = CollapseCandidate.Decision.COLLAPSE
    reasons: list = field(default_factory=list)
    penalty: float = 0.0


def build_plan(plan: CollapsePlan) -> CollapsePlan:
    """Read the file and fill ``plan`` with candidates. The worker entrypoint."""
    source = plan.source
    connector = get_connector(source.system_key)
    if connector is None:
        raise MigrationError(f"Unknown source system: {source.system_key!r}.")
    if PRODUCT not in set(connector.supported_entities):
        raise MigrationError("This system does not expose a product catalogue.")

    tracker = StageTracker(plan, BUILD_STAGES)
    context = ExtractContext(source=source, run_options={})
    transport = build_transport(connector.required_transport, source.connection_dict())
    with transport:
        tracker.start(READ_CATALOGUE)
        candidates = _read_catalogue(connector, transport, context)
        tracker.done(READ_CATALOGUE, f"{len(candidates):,} صنف")

        tracker.start(READ_HISTORY)
        read = _read_history(connector, transport, context, candidates)
        tracker.done(READ_HISTORY, read)

    tracker.start(CLUSTER)
    clusters = _cluster(candidates)
    tracker.done(CLUSTER, f"{len(clusters):,} منتج")

    tracker.start(PROPOSE)
    _judge(candidates, clusters)
    _persist(plan, candidates)
    plan.asset_type = plan.asset_type or _guess_asset_type(candidates)
    plan.built_at = timezone.now()
    plan.status = CollapsePlan.Status.READY
    plan.save(update_fields=["asset_type", "built_at", "status", "updated_at"])
    recompute_stats(plan)
    tracker.done(PROPOSE, _headline(plan.stats))
    return plan


# --- reading -----------------------------------------------------------------


def _read_catalogue(connector, transport, context) -> dict:
    """Every product in the file, parsed, keyed by its source key.

    Variants are read only to find the products that have more than one — a
    product with two sellable rows is not the one-product-per-handset shape, and
    collapsing it would merge two different things into one unit.
    """
    supported = set(connector.supported_entities)
    variants_of = defaultdict(list)
    prices = {}
    barcodes = {}
    if VARIANT in supported:
        for record in connector.extract(VARIANT, transport, context):
            product_key = str(record.product_source_key or "")
            variants_of[product_key].append(str(record.source_key))
            prices[str(record.source_key)] = record.unit_price
            barcodes[str(record.source_key)] = record.barcode or ""

    candidates: dict[str, _Candidate] = {}
    for record in connector.extract(PRODUCT, transport, context):
        key = str(record.source_key)
        name = (record.name or "").strip()
        keys = variants_of.get(key) or []
        variant_key = keys[0] if len(keys) == 1 else key
        candidate = _Candidate(
            source_key=key,
            source_name=name[:255],
            variant_source_key=variant_key,
            extraction=extract_name(name),
            list_price=prices.get(variant_key, record.unit_price),
            legacy_barcode=str(barcodes.get(variant_key, record.barcode) or "")[:64],
        )
        if len(keys) > 1:
            candidate.reasons.append("multiple_variants")
            candidate.decision = CollapseCandidate.Decision.KEEP
        if record.is_service or record.is_prepared:
            # §4.2 refuses a tracked service at both ends. A migration that
            # created one would be refused at the first save anyway; better to
            # say so on the review screen than in a stack trace.
            candidate.reasons.append("not_stock_keeping")
            candidate.decision = CollapseCandidate.Decision.KEEP
        candidates[key] = candidate
    return candidates


def _read_history(connector, transport, context, candidates) -> str:
    """Fold the file's purchases, sales and stock into each candidate.

    One pass per entity, and only for products that could be collapsed at all —
    the accumulators are keyed on candidate keys, so a 900,000-invoice file
    costs a walk rather than a table.
    """
    supported = set(connector.supported_entities)
    by_variant_key = {
        candidate.variant_source_key: candidate
        for candidate in candidates.values()
        if candidate.decision == CollapseCandidate.Decision.COLLAPSE
        and candidate.extraction.collapsible
    }
    if not by_variant_key:
        return "لا يوجد ما يُقرأ"

    purchases = sales = 0
    if PURCHASE_ORDER in supported:
        for record in connector.extract(PURCHASE_ORDER, transport, context):
            if str(getattr(record, "status", "")) == "cancelled":
                continue
            purchases += 1
            for line in record.lines or []:
                candidate = by_variant_key.get(str(line.variant_source_key))
                if candidate is not None:
                    _observe_purchase(candidate.evidence, record, line)
    if SALE in supported:
        for record in connector.extract(SALE, transport, context):
            if str(getattr(record, "status", "")) == "void":
                continue
            sales += 1
            for line in record.lines or []:
                candidate = by_variant_key.get(str(line.variant_source_key))
                if candidate is not None:
                    _observe_sale(candidate.evidence, record, line)
    if STOCK in supported:
        for record in connector.extract(STOCK, transport, context):
            candidate = by_variant_key.get(str(record.variant_source_key))
            if candidate is not None:
                candidate.evidence.stock_quantity = Decimal(record.quantity_on_hand or 0)
    return f"{purchases:,} شراء · {sales:,} بيع"


def _observe_purchase(evidence, record, line) -> None:
    """The *first* purchase wins: it is when the shop acquired this article."""
    quantity = Decimal(line.quantity or 0)
    if quantity <= 0:
        return
    evidence.purchased_quantity += quantity
    occurred_at = _aware(getattr(record, "occurred_at", None))
    first = evidence.acquired_at is None or (
        occurred_at is not None and occurred_at < evidence.acquired_at
    )
    if first or evidence.unit_cost <= ZERO:
        evidence.unit_cost = Decimal(line.unit_cost or 0)
        evidence.supplier_source_key = str(record.supplier_source_key or "")
        if occurred_at is not None:
            evidence.acquired_at = occurred_at


def _observe_sale(evidence, record, line) -> None:
    """The *last* sale wins: it is when the article left."""
    quantity = Decimal(line.quantity or 0)
    if quantity <= 0:
        return
    evidence.sold_quantity += quantity
    occurred_at = _aware(getattr(record, "occurred_at", None))
    last = evidence.sold_at is None or (occurred_at is not None and occurred_at >= evidence.sold_at)
    if last:
        evidence.sold_price = Decimal(line.unit_price or 0)
        evidence.sale_source_key = str(record.source_key or "")
        if occurred_at is not None:
            evidence.sold_at = occurred_at


def _aware(value):
    """A source date, in the shop's timezone.

    Connectors read whatever the old system stored, which is a naive local
    timestamp in every one of them. Stamping that onto a unit unconverted is how
    an article acquired at nine in the morning shows up in the aging report on
    the wrong day.
    """
    if value is None or not timezone.is_naive(value):
        return value
    return timezone.make_aware(value)


# --- clustering and judgement ------------------------------------------------


def _cluster(candidates) -> dict:
    """``{stem_key: [source_key, …]}`` over the rows still in the running."""
    clusters = defaultdict(list)
    for candidate in candidates.values():
        if candidate.decision != CollapseCandidate.Decision.COLLAPSE:
            continue
        if not candidate.extraction.collapsible:
            continue
        clusters[candidate.extraction.stem_key].append(candidate.source_key)
    return clusters


def _judge(candidates, clusters) -> None:
    """Apply everything that can only be known once the whole file is read.

    The premise check lives here rather than in the parser because it is not
    about the name at all: it is about whether the documents behave the way one
    product per physical article behaves.
    """
    live_identifiers = defaultdict(list)
    for candidate in candidates.values():
        extraction = candidate.extraction
        if candidate.decision != CollapseCandidate.Decision.COLLAPSE:
            continue
        if not extraction.collapsible:
            candidate.decision = CollapseCandidate.Decision.KEEP
            continue

        evidence = candidate.evidence
        if evidence.purchased_quantity > 1:
            candidate.reasons.append("purchased_more_than_once")
            candidate.decision = CollapseCandidate.Decision.KEEP
        if evidence.sold_quantity > 1:
            candidate.reasons.append("sold_more_than_once")
            candidate.decision = CollapseCandidate.Decision.KEEP
        if evidence.stock_quantity is not None and evidence.stock_quantity > 1:
            candidate.reasons.append("more_than_one_on_hand")
            candidate.decision = CollapseCandidate.Decision.KEEP
        if candidate.decision != CollapseCandidate.Decision.COLLAPSE:
            continue

        if len(clusters.get(extraction.stem_key, ())) <= SINGLETON:
            candidate.reasons.append("singleton_cluster")
            candidate.penalty += 0.2
        if evidence.unit_cost <= ZERO:
            candidate.reasons.append("no_purchase_cost")
            candidate.penalty += 0.1
        if _status_of(candidate) == CollapseCandidate.UnitStatus.SOLD and not (
            evidence.sold_quantity
        ):
            candidate.reasons.append("gone_without_a_sale")
            candidate.penalty += 0.1
        if _is_live(candidate):
            live_identifiers[extraction.identifier].append(candidate)

    # A legacy barcode is carried onto the unit as its secondary code, so the
    # shop's printed labels keep scanning. That only holds while the barcode
    # names *one* article: a code several rows share is a product-level shelf
    # label, and attaching it to four handsets would make a scan at the till
    # ambiguous in exactly the way identity is supposed to prevent.
    shared = defaultdict(int)
    for candidate in candidates.values():
        if candidate.decision == CollapseCandidate.Decision.COLLAPSE:
            shared[candidate.legacy_barcode] += 1
    for candidate in candidates.values():
        if shared.get(candidate.legacy_barcode, 0) > 1:
            candidate.legacy_barcode = ""

    # §7: one *live* unit per identifier. Two sold rows sharing an IMEI is an
    # ordinary handset traded twice and is imported as two units; two rows both
    # claiming to be on the shelf is a conflict nobody but the owner can settle,
    # so the later ones keep their shape and say why.
    for identifier, sharing in live_identifiers.items():
        if len(sharing) < 2:
            continue
        for candidate in sharing[1:]:
            candidate.reasons.append("duplicate_identifier")
            candidate.decision = CollapseCandidate.Decision.KEEP

    # The same rule against the shop's *own* shelf. A second file, or a shop
    # that started identifying by hand before it migrated, can hold a handset
    # this file also claims — and the owner is the only one who knows which
    # record is the real one.
    for candidate in _already_in_stock(live_identifiers):
        if candidate.decision != CollapseCandidate.Decision.COLLAPSE:
            continue  # already kept for a reason of its own; one is enough
        candidate.reasons.append("identifier_already_in_stock")
        candidate.decision = CollapseCandidate.Decision.KEEP


def _already_in_stock(live_identifiers):
    """Candidates whose identifier is already live in this shop's stock."""
    from apps.inventory.models import StockUnit

    if not live_identifiers:
        return []
    codes = list(live_identifiers)
    taken = set()
    for start in range(0, len(codes), 500):
        taken |= set(
            StockUnit.objects.filter(
                code_normalized__in=codes[start : start + 500],
                status__in=StockUnit.LIVE_STATUSES,
            ).values_list("code_normalized", flat=True)
        )
    return [candidate for code in taken for candidate in live_identifiers.get(code, [])]


def _is_live(candidate) -> bool:
    return _status_of(candidate) == CollapseCandidate.UnitStatus.IN_STOCK


def _status_of(candidate) -> str:
    """Where this article is now, from the old system's own answer.

    The stock table decides when the file has one, because a running balance is
    the old system's statement about today and a sale is its statement about a
    Tuesday in 2023. With no stock table, a sale is the only evidence there is.
    """
    evidence = candidate.evidence
    if evidence.stock_quantity is not None:
        if evidence.stock_quantity >= 1:
            return CollapseCandidate.UnitStatus.IN_STOCK
        return CollapseCandidate.UnitStatus.SOLD
    if evidence.sold_quantity > 0:
        return CollapseCandidate.UnitStatus.SOLD
    return CollapseCandidate.UnitStatus.IN_STOCK


def _guess_asset_type(candidates):
    """The registry row whose identity fields match what the file turned out to
    hold. A phone shop should not have to pick "phone" off a list."""
    from apps.customers.models import AssetType

    kinds = defaultdict(int)
    for candidate in candidates.values():
        if candidate.decision == CollapseCandidate.Decision.COLLAPSE:
            kinds[candidate.extraction.identifier_kind] += 1
    if not kinds:
        return None
    dominant = max(kinds, key=kinds.get)
    lookup = {
        IdentifierKind.IMEI: {"tracks_imei": True},
        IdentifierKind.VIN: {"tracks_vin": True},
    }.get(dominant)
    if lookup is None:
        return AssetType.objects.filter(slug="other").first()
    return (
        AssetType.objects.filter(is_active=True, **lookup).order_by("display_order", "pk").first()
    ) or AssetType.objects.filter(slug="other").first()


# --- persistence -------------------------------------------------------------


@transaction.atomic
def _persist(plan, candidates) -> None:
    plan.candidates.all().delete()
    rows = []
    for candidate in candidates.values():
        extraction = candidate.extraction
        evidence = candidate.evidence
        collapsing = candidate.decision == CollapseCandidate.Decision.COLLAPSE
        confidence = max(0.0, extraction.confidence - candidate.penalty)
        rows.append(
            CollapseCandidate(
                plan=plan,
                source_key=candidate.source_key,
                source_name=candidate.source_name,
                variant_source_key=candidate.variant_source_key,
                legacy_barcode=candidate.legacy_barcode,
                decision=candidate.decision,
                stem=extraction.stem[:255] if collapsing else "",
                stem_key=extraction.stem_key[:255] if collapsing else "",
                identifier=extraction.identifier if collapsing else "",
                identifier_kind=extraction.identifier_kind if collapsing else "",
                options=dict(extraction.options) if collapsing else {},
                attributes=dict(extraction.attributes) if collapsing else {},
                unit_status=_status_of(candidate),
                unit_cost=evidence.unit_cost,
                list_price=candidate.list_price,
                sold_price=evidence.sold_price,
                acquired_at=evidence.acquired_at,
                sold_at=evidence.sold_at,
                supplier_source_key=evidence.supplier_source_key[:255],
                sale_source_key=evidence.sale_source_key[:255],
                confidence=round(Decimal(str(confidence)), 2),
                reasons=[*extraction.reasons, *candidate.reasons],
            )
        )
    CollapseCandidate.objects.bulk_create(rows, batch_size=500)


def clusters_for(plan) -> list:
    """The proposal as products: what each one is called and what it holds.

    Derived from the candidate rows on every read rather than stored, which is
    what makes "these two are the same phone" an edit to a name.
    """
    grouped = defaultdict(list)
    rows = plan.candidates.filter(decision=CollapseCandidate.Decision.COLLAPSE).order_by(
        "stem_key", "confidence", "id"
    )
    for row in rows:
        grouped[row.stem_key].append(row)

    clusters = []
    for stem_key, members in grouped.items():
        variants = {}
        for member in members:
            variants.setdefault(_variant_key(member.options), member.options)
        in_stock = sum(
            1 for member in members if member.unit_status == CollapseCandidate.UnitStatus.IN_STOCK
        )
        clusters.append(
            {
                "stem_key": stem_key,
                "stem": members[0].stem,
                "products": 1,
                "variants": len(variants),
                "units": len(members),
                "units_in_stock": in_stock,
                "units_sold": len(members) - in_stock,
                "lowest_confidence": min(member.confidence for member in members),
                "needs_review": sum(
                    1 for member in members if float(member.confidence) < LOW_CONFIDENCE
                ),
                "option_values": _option_summary(variants.values()),
                # The same values as a shop reads them — «أزرق», not «blue».
                # Sent rather than mapped client-side because the lexicon that
                # named them lives here (`collapse.extract`), and a second copy
                # of it in Dart is a second answer to what a colour is called.
                "option_labels": _option_labels(variants.values()),
            }
        )
    clusters.sort(key=lambda cluster: (-cluster["units"], cluster["stem"]))
    return clusters


def _variant_key(options) -> str:
    return "|".join(f"{axis}={options[axis]}" for axis in sorted(options or {}))


def _option_summary(option_sets) -> dict:
    values = defaultdict(list)
    for options in option_sets:
        for axis, value in (options or {}).items():
            if value not in values[axis]:
                values[axis].append(value)
    return {axis: sorted(found) for axis, found in values.items()}


def _option_labels(option_sets) -> dict:
    return {
        axis: [parsing_option_label(axis, value) for value in values]
        for axis, values in _option_summary(option_sets).items()
    }


def recompute_stats(plan) -> dict:
    """ "340 products → 12 products, 31 variants, 340 units", counted afresh."""
    clusters = clusters_for(plan)
    collapsing = sum(cluster["units"] for cluster in clusters)
    total = plan.candidates.count()
    stats = {
        "source_products": total,
        "collapsing": collapsing,
        "kept": total - collapsing,
        "products": len(clusters),
        "variants": sum(cluster["variants"] for cluster in clusters),
        "units": collapsing,
        "units_in_stock": sum(cluster["units_in_stock"] for cluster in clusters),
        "units_sold": sum(cluster["units_sold"] for cluster in clusters),
        "needs_review": plan.candidates.filter(
            decision=CollapseCandidate.Decision.COLLAPSE,
            confidence__lt=Decimal(str(LOW_CONFIDENCE)),
        ).count(),
        "edited": plan.candidates.filter(edited=True).count(),
    }
    plan.stats = stats
    plan.save(update_fields=["stats", "updated_at"])
    return stats


def _headline(stats) -> str:
    return (
        f"{stats.get('source_products', 0):,} صنف → "
        f"{stats.get('products', 0):,} منتج · "
        f"{stats.get('variants', 0):,} خيار · "
        f"{stats.get('units', 0):,} وحدة"
    )


__all__ = ["build_plan", "clusters_for", "recompute_stats"]
