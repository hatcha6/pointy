"""Catch a purchase cost that is obviously a typo before it poisons margin.

The failure this exists to stop, from a first client's data: a cashier bought
bread for cash at the till, paid 130 LYD for a stack of loaves, and entered it as
``quantity 1 × unit_cost 130``. From that moment every loaf was recorded as
costing 130 LYD against a 1.00 LYD selling price, and the next 75 sales each
booked a 129 LYD loss. Across all products, 348 sale lines carried a cost more
than triple their price and erased 54,537 LYD of gross margin — about eleven
points of the shop's revenue — from every report built on it.

Nothing caught it. ``prevent_selling_at_loss`` gates the wrong end of the
transaction (and was off), and no check compared a new cost against either the
selling price or the cost history.

Two independent signals, both computed **per base unit**, because that is the
only scale on which a cost and a price are comparable — a 162-per-carton egg
line is 0.45 per egg, not a 161-dinar loss (see
``PurchaseLine.effective_base_unit_cost``):

``above_sale_price``
    the new cost exceeds what the item sells for, so every sale loses money.
``cost_spike``
    the new cost is a large multiple of what this item last cost.

Each anomaly carries the ratio that triggered it, and the same ratios are read
at two thresholds:

*Warn* — the purchasing screen. A manager pricing clearance stock or entering a
genuinely thin margin should not be blocked, only asked to confirm.

*Block* — a POS cash purchase. That path is used by cashiers, who cannot judge
whether a cost is plausible and have no way to override; it must refuse rather
than record something nobody will notice for weeks. The blocking threshold is
deliberately looser than the warning one, so a legitimately thin-margin cash
purchase still goes through and only an implausible one is stopped.
"""

from decimal import Decimal

from django.conf import settings

from .services import latest_purchase_line_for_variant

ABOVE_SALE_PRICE = "above_sale_price"
COST_SPIKE = "cost_spike"


def _ratio_setting(name, default):
    try:
        value = Decimal(str(getattr(settings, name, default)))
    except Exception:  # pragma: no cover - defensive against a bad env value
        return Decimal(str(default))
    return value if value > 0 else Decimal(str(default))


def warn_thresholds():
    return {
        ABOVE_SALE_PRICE: _ratio_setting("POINTY_PURCHASE_COST_WARN_PRICE_RATIO", "3"),
        COST_SPIKE: _ratio_setting("POINTY_PURCHASE_COST_WARN_SPIKE_RATIO", "5"),
    }


def block_thresholds():
    return {
        ABOVE_SALE_PRICE: _ratio_setting("POINTY_PURCHASE_COST_BLOCK_PRICE_RATIO", "5"),
        COST_SPIKE: _ratio_setting("POINTY_PURCHASE_COST_BLOCK_SPIKE_RATIO", "10"),
    }


class CostAnomaly:
    """One suspicious line, with the arithmetic that made it suspicious.

    The numbers travel with the finding so the client can show a cashier or
    manager *why* — "you are recording 130.00 per piece for something that sells
    for 1.00" reads as an obvious mistake, where "invalid cost" reads as the
    software being difficult.
    """

    __slots__ = ("index", "kind", "ratio", "base_unit_cost", "reference", "variant")

    def __init__(self, *, index, kind, ratio, base_unit_cost, reference, variant):
        self.index = index
        self.kind = kind
        self.ratio = ratio
        self.base_unit_cost = base_unit_cost
        self.reference = reference
        self.variant = variant

    @property
    def product_name(self):
        variant = self.variant
        if variant is None:
            return ""
        name = getattr(getattr(variant, "product", None), "name", "") or ""
        variant_name = (getattr(variant, "name", "") or "").strip()
        return f"{name} - {variant_name}" if variant_name else name

    @property
    def message(self):
        if self.kind == ABOVE_SALE_PRICE:
            return (
                f"{self.product_name}: التكلفة {self.base_unit_cost} أعلى من سعر "
                f"البيع {self.reference}. تأكد من الكمية والسعر."
            )
        return (
            f"{self.product_name}: التكلفة {self.base_unit_cost} أعلى بكثير من آخر "
            f"تكلفة {self.reference}. تأكد من الكمية والسعر."
        )

    def as_payload(self, *, blocking=False):
        # Strings throughout: DRF runs every leaf of a ValidationError detail
        # through force_str, so anything that must survive the trip intact —
        # notably the blocking flag, which a bool does not — is stringified
        # deliberately rather than accidentally.
        return {
            "blocking": "true" if blocking else "false",
            "index": self.index,
            "kind": self.kind,
            "product_name": self.product_name,
            "variant_id": getattr(self.variant, "pk", None),
            "base_unit_cost": str(self.base_unit_cost),
            "reference": str(self.reference),
            "ratio": str(self.ratio.quantize(Decimal("0.01"))),
            "message": self.message,
        }


def _base_unit_cost(unit_cost, unit_factor):
    factor = unit_factor or Decimal("1")
    if factor <= 0:
        return Decimal(unit_cost)
    return (Decimal(unit_cost) / factor).quantize(Decimal("0.01"))


def _previous_base_unit_cost(variant_id):
    previous = latest_purchase_line_for_variant(variant_id)
    if previous is None:
        return None
    cost = previous.effective_base_unit_cost
    return cost if cost > 0 else None


def find_cost_anomalies(lines_data, *, thresholds):
    """Inspect validated purchase-line data and return what looks wrong.

    ``lines_data`` is ``PurchaseLineSerializer.validated_data`` — the unit and
    its base-conversion factor are already resolved there, so this reads the
    same numbers the line will be saved with.
    """
    anomalies = []
    for index, line in enumerate(lines_data):
        variant = line.get("variant")
        if variant is None:
            continue
        unit_cost = line.get("unit_cost")
        if unit_cost is None or Decimal(unit_cost) <= 0:
            continue
        cost = _base_unit_cost(unit_cost, line.get("unit_factor"))
        if cost <= 0:
            continue

        # A cost above the selling price means every sale loses money. Skipped
        # when the item has no price yet: a product being stocked before it is
        # priced is normal, and there is nothing to compare against.
        sale_price = Decimal(getattr(variant, "unit_price", 0) or 0)
        if sale_price > 0 and cost > sale_price * thresholds[ABOVE_SALE_PRICE]:
            anomalies.append(
                CostAnomaly(
                    index=index,
                    kind=ABOVE_SALE_PRICE,
                    ratio=cost / sale_price,
                    base_unit_cost=cost,
                    reference=sale_price,
                    variant=variant,
                )
            )
            continue

        # Otherwise: has this item's cost jumped implausibly? Catches the typo
        # even when the selling price is stale or unset — the case above misses
        # nothing here, so only one finding per line is reported.
        previous = _previous_base_unit_cost(getattr(variant, "pk", None))
        if previous is not None and cost > previous * thresholds[COST_SPIKE]:
            anomalies.append(
                CostAnomaly(
                    index=index,
                    kind=COST_SPIKE,
                    ratio=cost / previous,
                    base_unit_cost=cost,
                    reference=previous,
                    variant=variant,
                )
            )
    return anomalies
