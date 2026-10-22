"""Rule-driven bulk repricing: the pure half — the rule language and the plan.

A bulk price change is described by a **spec** with three parts:

``filter``
    Which variants are in play. A condition tree: a group says ``all`` (AND) or
    ``any`` (OR) of its children, and a child is a condition or another group,
    so "(category is Drinks OR supplier is Al-Waha) AND price < 5" is
    expressible. An empty group matches everything: "all products" is not a
    special case.

``steps``
    An ordered chain, each step applied to the price the previous one left
    behind. A step may carry its own ``when`` tree — evaluated against that
    *running* price, so "after +10%, anything now under 1.00 becomes 1.00" is a
    two-step chain — and may ``stop`` the chain for the rows it applied to,
    which is how "if A do X, else if B do Y" is written.

``finish``
    What always runs last, whatever the chain did: never below cost, and
    whether packs priced on their own move with their piece.

Prices live on variants, so a variant is the unit of planning: a product with
three sizes is three rows, each judged on its own price and cost. Nothing here
touches the database — :mod:`apps.catalog.bulk_pricing_data` loads the rows and
writes the result — so the whole language is testable on plain values, and the
preview and the apply cannot disagree: both run :func:`plan` on the same rows.
"""

from __future__ import annotations

import hashlib
from collections import defaultdict
from dataclasses import dataclass, field
from decimal import ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_UP, Decimal, InvalidOperation

from rest_framework.exceptions import ValidationError

from . import search_text

HUNDRED = Decimal("100")
ZERO = Decimal("0")

MAX_DEPTH = 3
MAX_CONDITIONS = 60
MAX_STEPS = 20
MAX_LIST_VALUES = 500
# A change this large (either way) is flagged in the preview. Not refused: a
# shop correcting a mistyped 0.50 to 5.00 means it.
BIG_CHANGE_PERCENT = Decimal("50")

MATCH_ALL = "all"
MATCH_ANY = "any"

TEXT, NUMBER, REFS, BOOL = "text", "number", "refs", "bool"

# field -> kind. ``cost`` and ``markup`` read cost, which only some roles see.
FIELDS = {
    "name": TEXT,
    "sku": TEXT,
    "barcode": TEXT,
    "category": REFS,
    "supplier": REFS,
    "product": REFS,
    "price": NUMBER,
    "cost": NUMBER,
    "markup": NUMBER,
    "stock": NUMBER,
    "is_active": BOOL,
    "is_service": BOOL,
    "foreign_priced": BOOL,
}
COST_FIELDS = frozenset({"cost", "markup"})

TEXT_OPS = frozenset(
    {
        "contains",
        "not_contains",
        "equals",
        "not_equals",
        "starts_with",
        "ends_with",
        "is_empty",
        "is_not_empty",
    }
)
NUMBER_OPS = frozenset(
    {"eq", "neq", "gt", "gte", "lt", "lte", "between", "is_empty", "is_not_empty"}
)
REF_OPS = frozenset({"in", "not_in", "is_empty", "is_not_empty"})
BOOL_OPS = frozenset({"is_true", "is_false"})
OPS_BY_KIND = {TEXT: TEXT_OPS, NUMBER: NUMBER_OPS, REFS: REF_OPS, BOOL: BOOL_OPS}
VALUELESS_OPS = frozenset({"is_empty", "is_not_empty", "is_true", "is_false"})
# For a field that can hold several values at once (a variant's barcodes), a
# negative operator means "none of them", a positive one "any of them".
NEGATIVE_TEXT_OPS = frozenset({"not_contains", "not_equals"})

# action -> needs cost
ACTIONS = {
    "set": False,
    "increase_percent": False,
    "decrease_percent": False,
    "increase_amount": False,
    "decrease_amount": False,
    "cost_markup": True,
    "cost_plus": True,
    "min_price": False,
    "max_price": False,
    "min_markup": True,
    "round": False,
    "ending": False,
}
DIRECTIONS = frozenset({"nearest", "up", "down"})
PACK_MODES = frozenset({"scale", "keep"})

FLAG_NO_COST = "no_cost"
FLAG_BELOW_COST = "below_cost"
FLAG_RAISED_TO_COST = "raised_to_cost"
FLAG_ZERO = "zero"
FLAG_BIG_CHANGE = "big_change"
FLAG_FOREIGN = "foreign"
WARNING_FLAGS = frozenset(
    {FLAG_NO_COST, FLAG_BELOW_COST, FLAG_RAISED_TO_COST, FLAG_ZERO, FLAG_BIG_CHANGE}
)


# -- the spec ----------------------------------------------------------------


@dataclass(frozen=True)
class Condition:
    field: str
    op: str
    # Prepared once at parse time: folded text, Decimals, an id set.
    value: object = None
    value_to: object = None


@dataclass(frozen=True)
class Group:
    match: str
    children: tuple = ()

    @property
    def is_empty(self) -> bool:
        return not self.children


@dataclass(frozen=True)
class Step:
    action: str
    value: Decimal | None
    direction: str = "nearest"
    when: Group | None = None
    stop: bool = False


@dataclass(frozen=True)
class Spec:
    filter: Group
    steps: tuple
    never_below_cost: bool = False
    packs: str = "scale"
    # The request exactly as validated, for the history record.
    normalized: dict = field(default_factory=dict, compare=False)

    def fields_used(self) -> set[str]:
        used: set[str] = set()
        _collect_fields(self.filter, used)
        for step in self.steps:
            if step.when is not None:
                _collect_fields(step.when, used)
        return used

    @property
    def needs_cost(self) -> bool:
        return (
            bool(self.fields_used() & COST_FIELDS)
            or self.never_below_cost
            or any(ACTIONS[step.action] for step in self.steps)
        )


def _collect_fields(group: Group, into: set[str]) -> None:
    for child in group.children:
        if isinstance(child, Group):
            _collect_fields(child, into)
        else:
            into.add(child.field)


def _fail(path: str, message: str, code: str = "invalid"):
    raise ValidationError({path: [message]}, code=code)


def _decimal(raw, path: str, *, minimum: Decimal | None = ZERO, places: int = 2):
    if isinstance(raw, bool) or raw is None or raw == "":
        _fail(path, "A number is required.", "required")
    try:
        value = Decimal(str(raw).strip())
    except (InvalidOperation, ValueError):
        _fail(path, "Not a number.")
    if not value.is_finite():
        _fail(path, "Not a number.")
    if minimum is not None and value < minimum:
        _fail(path, f"Must be at least {minimum}.", "min_value")
    if value.as_tuple().exponent < -places:
        _fail(path, f"At most {places} decimal places.", "max_decimal_places")
    if abs(value) >= Decimal("100000000"):
        _fail(path, "Too large.", "max_value")
    return value


def _ids(raw, path: str) -> frozenset:
    if not isinstance(raw, list) or not raw:
        _fail(path, "Pick at least one.", "required")
    if len(raw) > MAX_LIST_VALUES:
        _fail(path, f"At most {MAX_LIST_VALUES} values.", "max_length")
    ids = set()
    for item in raw:
        if isinstance(item, bool):
            _fail(path, "Ids must be whole numbers.")
        try:
            value = int(item)
        except (TypeError, ValueError):
            _fail(path, "Ids must be whole numbers.")
        if value < 1 or str(item).strip() != str(value):
            _fail(path, "Ids must be whole numbers.")
        ids.add(value)
    return frozenset(ids)


class _Budget:
    def __init__(self):
        self.conditions = 0


def parse_group(raw, path: str, *, cost_visible: bool, depth=1, budget=None) -> Group:
    budget = budget or _Budget()
    if raw is None:
        return Group(MATCH_ALL)
    if not isinstance(raw, dict):
        _fail(path, "Expected a group.")
    if depth > MAX_DEPTH:
        _fail(path, f"Groups nest at most {MAX_DEPTH} deep.", "max_depth")
    match = raw.get("match", MATCH_ALL)
    if match not in (MATCH_ALL, MATCH_ANY):
        _fail(f"{path}.match", "Must be 'all' or 'any'.")
    items = raw.get("conditions", [])
    if not isinstance(items, list):
        _fail(f"{path}.conditions", "Expected a list.")
    children = []
    for index, item in enumerate(items):
        child_path = f"{path}.conditions[{index}]"
        if isinstance(item, dict) and "conditions" in item:
            child = parse_group(
                item, child_path, cost_visible=cost_visible, depth=depth + 1, budget=budget
            )
            # An empty sub-group constrains nothing; dropping it keeps "any"
            # groups from being satisfied by a blank row the user never filled.
            if not child.is_empty:
                children.append(child)
            continue
        budget.conditions += 1
        if budget.conditions > MAX_CONDITIONS:
            _fail(path, f"At most {MAX_CONDITIONS} conditions.", "max_length")
        children.append(parse_condition(item, child_path, cost_visible=cost_visible))
    return Group(match, tuple(children))


def parse_condition(raw, path: str, *, cost_visible: bool) -> Condition:
    if not isinstance(raw, dict):
        _fail(path, "Expected a condition.")
    name = raw.get("field")
    kind = FIELDS.get(name)
    if kind is None:
        _fail(f"{path}.field", "Unknown field.")
    if name in COST_FIELDS and not cost_visible:
        _fail(f"{path}.field", "Cost is not visible to you.", "cost_not_permitted")
    op = raw.get("op")
    if op not in OPS_BY_KIND[kind]:
        _fail(f"{path}.op", "This comparison does not apply to this field.")
    if op in VALUELESS_OPS:
        return Condition(name, op)
    value = raw.get("value")
    if kind == TEXT:
        text = "" if value is None else str(value)
        folded = _fold(name, text)
        if not folded:
            _fail(f"{path}.value", "Type something to compare with.", "required")
        return Condition(name, op, folded)
    if kind == REFS:
        return Condition(name, op, _ids(value, f"{path}.value"))
    # NUMBER: stock and markup may be negative (stock oversold, sold at a loss).
    minimum = None if name in {"stock", "markup"} else ZERO
    places = 3 if name == "stock" else 2
    number = _decimal(value, f"{path}.value", minimum=minimum, places=places)
    if op != "between":
        return Condition(name, op, number)
    upper = _decimal(raw.get("value_to"), f"{path}.value_to", minimum=minimum, places=places)
    if upper < number:
        _fail(f"{path}.value_to", "The upper bound is below the lower one.")
    return Condition(name, op, number, upper)


def parse_step(raw, path: str, *, cost_visible: bool) -> Step:
    if not isinstance(raw, dict):
        _fail(path, "Expected a step.")
    action = raw.get("action")
    if action not in ACTIONS:
        _fail(f"{path}.action", "Unknown action.")
    if ACTIONS[action] and not cost_visible:
        _fail(f"{path}.action", "Cost is not visible to you.", "cost_not_permitted")
    value = _decimal(raw.get("value"), f"{path}.value")
    if action == "decrease_percent" and value > HUNDRED:
        _fail(f"{path}.value", "A decrease cannot exceed 100%.", "max_value")
    if action == "round" and value <= ZERO:
        _fail(f"{path}.value", "Round to a step above zero.", "min_value")
    direction = raw.get("direction") or "nearest"
    if direction not in DIRECTIONS:
        _fail(f"{path}.direction", "Must be nearest, up or down.")
    when = raw.get("when")
    parsed_when = None
    if when is not None:
        parsed_when = parse_group(when, f"{path}.when", cost_visible=cost_visible)
        if parsed_when.is_empty:
            parsed_when = None
    stop = raw.get("stop", False)
    if not isinstance(stop, bool):
        _fail(f"{path}.stop", "Must be true or false.")
    return Step(action, value, direction, parsed_when, stop)


def parse_spec(raw, *, cost_visible: bool) -> Spec:
    if not isinstance(raw, dict):
        _fail("spec", "Expected an object.")
    group = parse_group(raw.get("filter"), "filter", cost_visible=cost_visible)
    steps_raw = raw.get("steps")
    if not isinstance(steps_raw, list) or not steps_raw:
        _fail("steps", "Add at least one step.", "required")
    if len(steps_raw) > MAX_STEPS:
        _fail("steps", f"At most {MAX_STEPS} steps.", "max_length")
    steps = tuple(
        parse_step(step, f"steps[{index}]", cost_visible=cost_visible)
        for index, step in enumerate(steps_raw)
    )
    finish = raw.get("finish") or {}
    if not isinstance(finish, dict):
        _fail("finish", "Expected an object.")
    never_below_cost = finish.get("never_below_cost", False)
    if not isinstance(never_below_cost, bool):
        _fail("finish.never_below_cost", "Must be true or false.")
    if never_below_cost and not cost_visible:
        _fail("finish.never_below_cost", "Cost is not visible to you.", "cost_not_permitted")
    packs = finish.get("packs", "scale")
    if packs not in PACK_MODES:
        _fail("finish.packs", "Must be scale or keep.")
    normalized = {
        "filter": raw.get("filter") or {"match": MATCH_ALL, "conditions": []},
        "steps": [_normalized_step(step, raw_step) for step, raw_step in zip(steps, steps_raw)],
        "finish": {"never_below_cost": never_below_cost, "packs": packs},
    }
    return Spec(group, steps, never_below_cost, packs, normalized)


def _normalized_step(step: Step, raw: dict) -> dict:
    return {
        "action": step.action,
        "value": str(step.value),
        "direction": step.direction,
        "when": raw.get("when") if step.when is not None else None,
        "stop": step.stop,
    }


def _fold(name: str, text: str) -> str:
    if name == "name":
        return search_text.fold(text)
    return text.strip().upper()


# -- rows --------------------------------------------------------------------


@dataclass(frozen=True)
class PackRow:
    unit_id: int
    label: str
    price: Decimal


@dataclass(frozen=True)
class Row:
    """One variant as the planner sees it. Built by ``bulk_pricing_data``."""

    variant_id: int
    product_id: int
    product_name: str
    variant_name: str
    sku: str
    price: Decimal
    barcodes: tuple = ()
    category_ids: frozenset = frozenset()
    supplier_ids: frozenset = frozenset()
    cost: Decimal | None = None
    stock: Decimal = ZERO
    is_active: bool = True
    is_service: bool = False
    foreign_priced: bool = False
    is_default: bool = True
    packs: tuple = ()
    folded_name: str = ""

    @property
    def label(self) -> str:
        if self.variant_name and self.variant_name != self.product_name:
            return f"{self.product_name} — {self.variant_name}"
        return self.product_name


def markup_of(price: Decimal, cost: Decimal | None) -> Decimal | None:
    """Profit as a percentage of cost: (price - cost) / cost. None without a cost."""
    if cost is None or cost <= ZERO:
        return None
    return (price - cost) / cost * HUNDRED


# -- evaluation --------------------------------------------------------------


class Evaluator:
    """Evaluates condition trees. ``category`` conditions match a category's
    whole subtree, so it needs the shop's category tree once."""

    def __init__(self, category_children: dict[int, list[int]] | None = None):
        self._children = category_children or {}
        self._expanded: dict[frozenset, frozenset] = {}

    def subtree(self, ids: frozenset) -> frozenset:
        cached = self._expanded.get(ids)
        if cached is not None:
            return cached
        seen = set()
        stack = list(ids)
        while stack:
            current = stack.pop()
            if current in seen:
                continue
            seen.add(current)
            stack.extend(self._children.get(current, ()))
        result = frozenset(seen)
        self._expanded[ids] = result
        return result

    def matches(self, group: Group, row: Row, price: Decimal) -> bool:
        if group.is_empty:
            return True
        results = (
            self._child(child, row, price) for child in group.children
        )
        return all(results) if group.match == MATCH_ALL else any(results)

    def _child(self, child, row, price) -> bool:
        if isinstance(child, Group):
            return self.matches(child, row, price)
        return self.condition(child, row, price)

    def condition(self, cond: Condition, row: Row, price: Decimal) -> bool:
        kind = FIELDS[cond.field]
        if kind == BOOL:
            value = {
                "is_active": row.is_active,
                "is_service": row.is_service,
                "foreign_priced": row.foreign_priced,
            }[cond.field]
            return value if cond.op == "is_true" else not value
        if kind == REFS:
            return self._refs(cond, row)
        if kind == TEXT:
            return self._text(cond, row)
        return self._number(cond, row, price)

    def _refs(self, cond: Condition, row: Row) -> bool:
        if cond.field == "product":
            held = frozenset({row.product_id})
        elif cond.field == "category":
            held = row.category_ids
        else:
            held = row.supplier_ids
        if cond.op == "is_empty":
            return not held
        if cond.op == "is_not_empty":
            return bool(held)
        wanted = self.subtree(cond.value) if cond.field == "category" else cond.value
        hit = not held.isdisjoint(wanted)
        return hit if cond.op == "in" else not hit

    def _text(self, cond: Condition, row: Row) -> bool:
        if cond.field == "name":
            values = (row.folded_name,)
        elif cond.field == "sku":
            values = (row.sku.strip().upper(),) if row.sku.strip() else ()
        else:
            values = tuple(code.strip().upper() for code in row.barcodes if code.strip())
        if cond.op == "is_empty":
            return not any(values)
        if cond.op == "is_not_empty":
            return any(values)
        if cond.op in NEGATIVE_TEXT_OPS:
            positive = "contains" if cond.op == "not_contains" else "equals"
            return not any(_text_op(positive, value, cond.value) for value in values)
        return any(_text_op(cond.op, value, cond.value) for value in values)

    def _number(self, cond: Condition, row: Row, price: Decimal) -> bool:
        if cond.field == "price":
            value = price
        elif cond.field == "cost":
            value = row.cost
        elif cond.field == "markup":
            value = markup_of(price, row.cost)
        else:
            value = row.stock
        if cond.op == "is_empty":
            return value is None
        if cond.op == "is_not_empty":
            return value is not None
        # A row with no value never satisfies a comparison — not even "!=".
        # "Cost is not 5" is not a claim anyone can make about an unknown cost.
        if value is None:
            return False
        target = cond.value
        if cond.op == "eq":
            return value == target
        if cond.op == "neq":
            return value != target
        if cond.op == "gt":
            return value > target
        if cond.op == "gte":
            return value >= target
        if cond.op == "lt":
            return value < target
        if cond.op == "lte":
            return value <= target
        return target <= value <= cond.value_to  # between, inclusive


def _text_op(op: str, value: str, target: str) -> bool:
    if op == "contains":
        return target in value
    if op == "equals":
        return value == target
    if op == "starts_with":
        return value.startswith(target)
    return value.endswith(target)  # ends_with


# -- steps -------------------------------------------------------------------


def round_to(price: Decimal, increment: Decimal, direction: str) -> Decimal:
    mode = {"nearest": ROUND_HALF_UP, "up": ROUND_CEILING, "down": ROUND_FLOOR}[direction]
    return (price / increment).quantize(Decimal("1"), rounding=mode) * increment


def with_ending(price: Decimal, ending: Decimal, direction: str) -> Decimal:
    """The price nearest ``price`` that ends in ``ending``.

    The ending's own size picks the cycle: ``0.99`` / ``0.50`` repeat every
    1.00, ``9`` every 10, ``4.99`` and ``95`` every 10 and 100. So 12.30 with
    ending 0.99 is 12.99 up or 11.99 down, and with ending 9 is 19 up or 9 down.
    Never goes below zero: a "down" with no non-negative candidate goes up.
    """
    whole_digits = len(str(int(ending))) if ending >= 1 else 0
    cycle = Decimal(10) ** whole_digits
    base = (price / cycle).to_integral_value(rounding=ROUND_FLOOR) * cycle + ending
    if base >= price:
        upper, lower = base, base - cycle
    else:
        upper, lower = base + cycle, base
    if lower < ZERO or direction == "up":
        return upper
    if direction == "down":
        return lower
    return upper if (upper - price) <= (price - lower) else lower


def apply_step(step: Step, price: Decimal, cost: Decimal | None) -> Decimal | None:
    """The price after ``step``, or None when the step needs a cost the row lacks."""
    value = step.value
    action = step.action
    if ACTIONS[action] and cost is None:
        return None
    if action == "set":
        return value
    if action == "increase_percent":
        return price * (HUNDRED + value) / HUNDRED
    if action == "decrease_percent":
        return price * (HUNDRED - value) / HUNDRED
    if action == "increase_amount":
        return price + value
    if action == "decrease_amount":
        return price - value
    if action == "cost_markup":
        return cost * (HUNDRED + value) / HUNDRED
    if action == "cost_plus":
        return cost + value
    if action == "min_price":
        return max(price, value)
    if action == "max_price":
        return min(price, value)
    if action == "min_markup":
        return max(price, cost * (HUNDRED + value) / HUNDRED)
    if action == "round":
        return round_to(price, value, step.direction)
    return with_ending(price, value, step.direction)  # ending


# -- the plan ----------------------------------------------------------------


@dataclass(frozen=True)
class PackChange:
    unit_id: int
    label: str
    old_price: Decimal
    new_price: Decimal


@dataclass(frozen=True)
class RowResult:
    row: Row
    new_price: Decimal
    applied: tuple
    flags: frozenset
    packs: tuple = ()

    @property
    def changed(self) -> bool:
        return self.new_price != self.row.price or bool(self.packs)

    @property
    def price_changed(self) -> bool:
        return self.new_price != self.row.price

    @property
    def delta(self) -> Decimal:
        return self.new_price - self.row.price

    @property
    def delta_percent(self) -> Decimal | None:
        if self.row.price <= ZERO:
            return None
        return (self.delta / self.row.price * HUNDRED).quantize(Decimal("0.1"), ROUND_HALF_UP)

    @property
    def has_warning(self) -> bool:
        return not self.flags.isdisjoint(WARNING_FLAGS)


@dataclass
class Plan:
    results: list
    quantum: Decimal
    step_total: int = 0

    @property
    def changed(self) -> list:
        return [result for result in self.results if result.changed]

    def fingerprint(self) -> str:
        """A digest of every write this plan would make, old and new value.

        The apply recomputes the plan under lock and refuses unless this
        matches what the preview showed — so a price edited elsewhere in the
        meantime, or a new purchase moving a cost, cannot slip a write in that
        nobody looked at.
        """
        lines = []
        for result in self.changed:
            if result.price_changed:
                lines.append(f"v:{result.row.variant_id}:{result.row.price}:{result.new_price}")
            for pack in result.packs:
                lines.append(f"u:{pack.unit_id}:{pack.old_price}:{pack.new_price}")
        lines.sort()
        return hashlib.sha256("\n".join(lines).encode()).hexdigest()

    def summary(self) -> dict:
        changed = self.changed
        increased = sum(1 for r in changed if r.new_price > r.row.price)
        decreased = sum(1 for r in changed if r.new_price < r.row.price)
        percents = [r.delta_percent for r in changed if r.price_changed and r.delta_percent is not None]
        average = (
            (sum(percents) / len(percents)).quantize(Decimal("0.1"), ROUND_HALF_UP)
            if percents
            else None
        )
        flags = {flag: 0 for flag in sorted(WARNING_FLAGS)}
        for result in self.results:
            for flag in result.flags & WARNING_FLAGS:
                flags[flag] += 1
        step_counts = defaultdict(int)
        for result in self.results:
            for index in result.applied:
                step_counts[index] += 1
        return {
            "matched": len(self.results),
            "step_counts": [step_counts[index] for index in range(self.step_total)],
            "changed": len(changed),
            "unchanged": len(self.results) - len(changed),
            "increased": increased,
            "decreased": decreased,
            "products_changed": len({r.row.product_id for r in changed}),
            "packs_changed": sum(len(r.packs) for r in changed),
            "average_change_percent": average,
            "warnings": sum(1 for r in self.results if r.has_warning),
            "flags": flags,
        }


def plan(spec: Spec, rows, *, evaluator: Evaluator | None = None, quantum=Decimal("0.01")) -> Plan:
    evaluator = evaluator or Evaluator()
    results = []
    for row in rows:
        if not evaluator.matches(spec.filter, row, row.price):
            continue
        results.append(_plan_row(spec, row, evaluator, quantum))
    return Plan(results, quantum, len(spec.steps))


def _plan_row(spec: Spec, row: Row, evaluator: Evaluator, quantum: Decimal) -> RowResult:
    price = row.price
    applied = []
    flags = set()
    if row.foreign_priced:
        flags.add(FLAG_FOREIGN)
    for index, step in enumerate(spec.steps):
        if step.when is not None and not evaluator.matches(step.when, row, price):
            continue
        result = apply_step(step, price, row.cost)
        if result is None:
            flags.add(FLAG_NO_COST)
            continue
        price = result
        applied.append(index)
        if step.stop:
            break
    if price < ZERO:
        price = ZERO
    price = price.quantize(quantum, rounding=ROUND_HALF_UP)
    if row.cost is not None and price < row.cost:
        if spec.never_below_cost:
            price = row.cost.quantize(quantum, rounding=ROUND_CEILING)
            flags.add(FLAG_RAISED_TO_COST)
        else:
            flags.add(FLAG_BELOW_COST)
    if spec.never_below_cost and row.cost is None:
        flags.add(FLAG_NO_COST)
    if price == ZERO and row.price > ZERO:
        flags.add(FLAG_ZERO)
    if price != row.price:
        if row.price <= ZERO or abs(price - row.price) / row.price * HUNDRED >= BIG_CHANGE_PERCENT:
            flags.add(FLAG_BIG_CHANGE)
    packs = ()
    if spec.packs == "scale" and row.is_default and price != row.price and row.price > ZERO:
        packs = tuple(
            change
            for change in (
                PackChange(
                    pack.unit_id,
                    pack.label,
                    pack.price,
                    (pack.price * price / row.price).quantize(quantum, rounding=ROUND_HALF_UP),
                )
                for pack in row.packs
            )
            if change.new_price != change.old_price
        )
    return RowResult(row, price, tuple(applied), frozenset(flags), packs)
