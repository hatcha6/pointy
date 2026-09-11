"""Reading a label a weighing scale printed.

A price-computing scale prints its own barcodes: an in-store prefix, the item's
short code, and a *value* — the weight it just measured, or the money that
weight costs. Nothing in the digits says which of the two it is. A 12.50 LYD
sticker and a 1.250 kg sticker are the same thirteen characters, and the only
thing that can tell them apart is knowing how the scale that printed them was
configured.

So this module never guesses. A shop declares its layouts as
:class:`~apps.catalog.models.ScaleBarcodeRule` rows, this module matches a
scanned code against them in order, and a code that matches nothing is simply
not a scale label — it goes on to be looked up as the plain barcode it appears
to be. The failure mode we are buying out of is not "the scan didn't work"; it
is a till that charges for 1.250 kg because 01250 was where grams live on
somebody else's scale.

The logic here is pure — rules in, a match out — so the identical decisions can
run in Dart at the till (``lib/src/shared/barcode/scale_barcode.dart``) against
the same vectors. Any change here belongs there in the same commit.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import ROUND_HALF_DOWN, ROUND_HALF_EVEN, Decimal

#: Pattern alphabet. One character per digit position.
ITEM = "I"  # a digit of the item (PLU) code
VALUE = "V"  # a digit of the embedded weight/price/count
CHECK = "C"  # the check digit
IGNORE = "X"  # a digit we neither identify by nor read (department, internal check)
PATTERN_ALPHABET = frozenset(ITEM + VALUE + CHECK + IGNORE + "0123456789")


class ValueKind:
    """What the embedded digits mean. Never inferred — always configured."""

    WEIGHT = "weight"
    PRICE = "price"
    COUNT = "count"

    CHOICES = (WEIGHT, PRICE, COUNT)


class ScaleRuleError(ValueError):
    """A pattern that could never match anything sane, caught at save time."""


@dataclass(frozen=True)
class ScaleRule:
    """One label layout, frozen for parsing.

    Mirrors the model row without importing it, so the parser stays usable from
    a test, a management command, or a serializer without touching the database.
    """

    pattern: str
    value_kind: str = ValueKind.WEIGHT
    value_decimals: int = 3
    value_unit: str = "kg"
    require_check_digit: bool = True
    name: str = ""
    rule_id: int | None = None

    def __post_init__(self) -> None:
        validate_pattern(self.pattern)
        if self.value_kind not in ValueKind.CHOICES:
            raise ScaleRuleError(f"Unknown value kind '{self.value_kind}'.")
        if self.value_decimals < 0:
            raise ScaleRuleError("Decimal places cannot be negative.")
        if self.value_decimals > self.pattern.count(VALUE):
            raise ScaleRuleError(
                "More decimal places than value digits: "
                f"{self.value_decimals} of {self.pattern.count(VALUE)}."
            )

    @property
    def length(self) -> int:
        return len(self.pattern)

    @property
    def has_check_digit(self) -> bool:
        return CHECK in self.pattern

    @property
    def literals(self) -> str:
        """The fixed digits, in position order — the rule's prefix, effectively."""

        return "".join(char for char in self.pattern if char.isdigit())

    @property
    def signature(self) -> tuple[int, str]:
        """Two rules with the same signature can match the same codes."""

        return (
            self.length,
            "".join(char if char.isdigit() else "." for char in self.pattern),
        )


@dataclass(frozen=True)
class ScaleBarcodeMatch:
    """A scanned code, understood."""

    raw: str
    rule: ScaleRule
    item_code: str
    #: The embedded number, already scaled by ``value_decimals``. Kilograms,
    #: money, or a count depending on ``rule.value_kind``.
    value: Decimal
    #: The code with the value digits zeroed and the check digit recomputed —
    #: what a shop that prints its own shelf labels stores on the product.
    base_code: str

    @property
    def value_kind(self) -> str:
        return self.rule.value_kind

    @property
    def is_zero_value(self) -> bool:
        """A label printed without weighing — or the shop's own shelf label.

        Either way there is no quantity in it, only an identity.
        """

        return self.value == 0

    @property
    def candidate_barcodes(self) -> tuple[str, ...]:
        """Codes to try against the catalog, most specific first.

        The base code comes first because it is the only candidate that is a
        whole, checkable barcode; a shop that prints shelf labels stores exactly
        that. The shorter forms follow for shops that store just the PLU.
        """

        trimmed = self.item_code.lstrip("0")
        prefix_and_item = self.raw[: _last_index(self.rule.pattern, ITEM) + 1]
        candidates = [
            self.base_code,
            prefix_and_item,
            self.item_code,
        ]
        if trimmed and trimmed != self.item_code:
            candidates.append(trimmed)
        seen: list[str] = []
        for candidate in candidates:
            if candidate and candidate not in seen:
                seen.append(candidate)
        return tuple(seen)


def validate_pattern(pattern: str) -> None:
    """Refuse a pattern that cannot describe a real label.

    Called from the model's ``clean`` so a shop finds out at the settings screen
    rather than at the counter.
    """

    if not pattern:
        raise ScaleRuleError("A pattern is required.")
    unknown = sorted(set(pattern) - PATTERN_ALPHABET)
    if unknown:
        raise ScaleRuleError(
            "Unknown pattern characters: " + ", ".join(repr(char) for char in unknown)
        )
    if ITEM not in pattern:
        raise ScaleRuleError("A pattern needs at least one item-code digit (I).")
    if VALUE not in pattern:
        raise ScaleRuleError("A pattern needs at least one value digit (V).")
    checks = pattern.count(CHECK)
    if checks > 1:
        raise ScaleRuleError("A pattern can hold at most one check digit (C).")
    if checks and not pattern.endswith(CHECK):
        raise ScaleRuleError("The check digit (C) must be the last position.")
    if not pattern[0].isdigit():
        raise ScaleRuleError(
            "A pattern must start with the literal prefix digits the scale prints, "
            "so it cannot swallow ordinary product barcodes."
        )


def check_digit(digits: str) -> str:
    """GS1 modulo-10 check digit over the data part of a code.

    Weights alternate 3 and 1 from the rightmost *data* digit, which is what
    makes the same function correct for EAN-13 (1,3,1,3…) and EAN-8 (3,1,3,1…)
    without either being special-cased.
    """

    total = 0
    length = len(digits)
    for index, char in enumerate(digits):
        weight = 3 if (length - index) % 2 else 1
        total += (ord(char) - 48) * weight
    return str((10 - total % 10) % 10)


def has_valid_check_digit(code: str) -> bool:
    return bool(code) and check_digit(code[:-1]) == code[-1]


def normalize_scanned(raw: str | None) -> str:
    """Whitespace off, nothing else. A scale label is digits or it is not ours."""

    return (raw or "").strip()


def parse(raw: str | None, rules) -> ScaleBarcodeMatch | None:
    """First rule that describes ``raw`` wins; ``None`` when none does."""

    code = normalize_scanned(raw)
    if not code or not code.isdigit():
        return None
    for rule in rules:
        match = _match_rule(code, rule)
        if match is not None:
            return match
    return None


def _match_rule(code: str, rule: ScaleRule) -> ScaleBarcodeMatch | None:
    if len(code) != rule.length:
        return None
    value_digits: list[str] = []
    item_digits: list[str] = []
    for char, digit in zip(rule.pattern, code):
        if char.isdigit():
            if char != digit:
                return None
        elif char == ITEM:
            item_digits.append(digit)
        elif char == VALUE:
            value_digits.append(digit)
    if rule.has_check_digit and rule.require_check_digit and not has_valid_check_digit(code):
        return None
    value = Decimal(int("".join(value_digits))).scaleb(-rule.value_decimals)
    return ScaleBarcodeMatch(
        raw=code,
        rule=rule,
        item_code="".join(item_digits),
        value=value,
        base_code=_base_code(code, rule),
    )


def _base_code(code: str, rule: ScaleRule) -> str:
    """The code with its value digits zeroed and the check digit put right.

    Odoo calls this the base code and looks products up by it; a shop that
    prints its own shelf labels has this exact string on the product, check
    digit and all, which is why recomputing it (rather than just zeroing) is the
    whole trick.
    """

    masked = [
        "0" if char == VALUE else digit for char, digit in zip(rule.pattern, code)
    ]
    if rule.has_check_digit:
        masked[-1] = check_digit("".join(masked[:-1]))
    return "".join(masked)


def _last_index(pattern: str, char: str) -> int:
    return pattern.rfind(char)


# --- What the value means for a line ----------------------------------------
#
# Parsing says "this label carries 12.50 of money". Turning that into a
# quantity needs the product, and every way that can go wrong has to end
# somewhere visible. These are the names the till says out loud.

#: The product is priced at zero, so a money label cannot be divided into a
#: quantity. Rings one; never divides by zero and calls it 500 kg.
WARN_NO_UNIT_PRICE = "no_unit_price"
#: The product is counted, not measured (its unit forbids fractions), so an
#: embedded weight is not a quantity for it. Rings one.
WARN_NOT_FRACTIONAL = "not_fractional"
#: The label's unit and the product's unit are not the same kind of thing (or
#: one of them has no conversion), so the weight cannot be carried across.
WARN_UNIT_MISMATCH = "unit_mismatch"
#: The derived quantity, at the three decimals a line stores, does not price
#: back to exactly what the sticker says. Small, but the cashier is told.
WARN_ROUNDING_DRIFT = "rounding_drift"

QUANTITY_STEP = Decimal("0.001")
MONEY_STEP = Decimal("0.01")
ONE = Decimal("1")


@dataclass(frozen=True)
class ScaleQuantity:
    """The quantity a scale label rings, and what was odd about getting there."""

    quantity: Decimal
    warning: str = ""
    #: What the sticker says the customer owes, when the label carries money.
    label_total: Decimal | None = None
    #: What the till will actually charge for ``quantity``. Equal to
    #: ``label_total`` unless rounding got in the way.
    rung_total: Decimal | None = None

    @property
    def drift(self) -> Decimal:
        if self.label_total is None or self.rung_total is None:
            return Decimal(0)
        return self.rung_total - self.label_total


def resolve_quantity(
    match: ScaleBarcodeMatch,
    *,
    unit_price: Decimal,
    allows_fractional: bool,
    unit_factor: Decimal | None = ONE,
) -> ScaleQuantity:
    """How many of the product's sale unit this label is worth.

    ``unit_factor`` converts one of the rule's ``value_unit`` into one of the
    product's sale unit (kg → g is 1000). ``None`` means the two units cannot be
    converted between, which is a configuration mistake and is reported rather
    than papered over.
    """

    # A zero value is an identity, not a measurement: the shop's own shelf
    # label, or a sticker printed with nothing on the pan. One of it.
    if match.is_zero_value:
        return ScaleQuantity(quantity=ONE)

    if match.value_kind == ValueKind.COUNT:
        return ScaleQuantity(quantity=_quantize_quantity(match.value))

    if match.value_kind == ValueKind.WEIGHT:
        if not allows_fractional:
            return ScaleQuantity(quantity=ONE, warning=WARN_NOT_FRACTIONAL)
        if unit_factor is None or unit_factor <= 0:
            return ScaleQuantity(quantity=ONE, warning=WARN_UNIT_MISMATCH)
        return ScaleQuantity(quantity=_quantize_quantity(match.value * unit_factor))

    # Money on the label. The line is priced by the server from the product, so
    # the quantity is what has to carry the sticker's total — and it can only
    # carry it to three decimals.
    label_total = match.value.quantize(MONEY_STEP)
    price = Decimal(unit_price or 0)
    if price <= 0:
        return ScaleQuantity(
            quantity=ONE,
            warning=WARN_NO_UNIT_PRICE,
            label_total=label_total,
        )
    # Nearest quantity, with a tie broken *downwards*. A sticker that cannot
    # be hit exactly at three decimals will be out by a step either way; going
    # down means the customer is never charged more than the label they were
    # shown, which is the half of the argument a shop cannot win at a counter.
    quantity = _quantize_quantity(label_total / price, rounding=ROUND_HALF_DOWN)
    if quantity <= 0:
        quantity = QUANTITY_STEP
    rung_total = (price * quantity).quantize(MONEY_STEP)
    return ScaleQuantity(
        quantity=quantity,
        warning=WARN_ROUNDING_DRIFT if rung_total != label_total else "",
        label_total=label_total,
        rung_total=rung_total,
    )


def _quantize_quantity(value: Decimal, *, rounding: str = ROUND_HALF_EVEN) -> Decimal:
    return Decimal(value).quantize(QUANTITY_STEP, rounding=rounding)


def build_code(rule: ScaleRule, item_code, value) -> str:
    """The code a scale following ``rule`` would print for this item and value.

    The inverse of :func:`parse`. Exists for three reasons: round-tripping every
    rule in tests, showing a shop a worked example of the layout it just
    configured, and — once PLUs are pushed — checking that the code the scale
    prints is the code we told it to print.
    """

    item_slots = rule.pattern.count(ITEM)
    value_slots = rule.pattern.count(VALUE)
    item_digits = str(item_code).strip().rjust(item_slots, "0")[-item_slots:]
    scaled = (Decimal(value) * (10 ** rule.value_decimals)).to_integral_value()
    value_digits = str(int(scaled)).rjust(value_slots, "0")[-value_slots:]
    if not item_digits.isdigit() or int(scaled) < 0:
        raise ScaleRuleError("Item code must be numeric and the value non-negative.")
    if len(str(int(scaled))) > value_slots:
        raise ScaleRuleError(
            f"{value} does not fit in {value_slots} digits at "
            f"{rule.value_decimals} decimal places."
        )

    items = iter(item_digits)
    values = iter(value_digits)
    out = []
    for char in rule.pattern:
        if char.isdigit():
            out.append(char)
        elif char == ITEM:
            out.append(next(items))
        elif char == VALUE:
            out.append(next(values))
        elif char == IGNORE:
            out.append("0")
        else:  # CHECK, always last
            out.append(check_digit("".join(out)))
    return "".join(out)
