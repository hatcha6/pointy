"""Import scopes — the named answers to "how much of this shop are we taking?"

Every migration so far has been treated as all-or-nothing, with a row of
checkboxes underneath for the operator to disagree with. That is the wrong
default twice over. A shop that has been trading for fifteen years usually does
**not** want fifteen years of invoices inside a new POS; what it wants is to
open tomorrow morning with its catalogue, its prices, its costs, and the right
number next to each customer's and supplier's name. Annaseem asked for exactly
that, in those words, and there was no way to say it.

A scope is that sentence, made executable: a named set of entities plus the run
options that go with them. It exists so the answer to "can you import only X?"
stops being a bespoke engineering conversation each time.

**The trap a scope exists to close.** Selecting fewer entities is not a
filter — it changes what the remaining numbers *mean*. Two cases, both silent:

* *Party balances.* A legacy system keeps a party's opening balance and their
  current one. Import the invoices and you must carry the **opening** figure and
  let the documents walk it forward; leave the invoices behind and you must
  carry the **current** one, because nothing is coming that would ever move it.
  Take the opening figure without the history and every customer starts on a
  debt from years ago; take the current figure *with* the history and every
  invoice is counted twice.
* *Cost without quantity.* "Products but no quantities" used to drop the stock
  entity whole — and the unit cost rides on that entity, so the shop opened with
  no cost on anything and booked the entire selling price of its first sale as
  profit. Cost and quantity are two different facts and a scope has to be able
  to ask for one without the other (see ``reconstruct.STOCK_SOURCE_COST_ONLY``).

So a scope pins the options as well as the entities, and
:func:`resolve_party_balance_basis` derives the basis from what is actually in
the run rather than from what anyone remembered to tick.
"""

from __future__ import annotations

from dataclasses import dataclass

from .entity_plan import (
    CATEGORY,
    CUSTOMER,
    PARTY_BALANCE,
    PAYMENT,
    PRODUCT,
    PRODUCT_UNIT,
    PURCHASE_ORDER,
    SALE,
    SALE_RETURN,
    SUPPLIER,
    SUPPLIER_PAYMENT,
    UNIT,
    VARIANT,
    all_entity_types,
    resolve_selection,
)
from .reconstruct import (
    STOCK_SOURCE_COST_ONLY,
    STOCK_SOURCE_NONE,
    STOCK_SOURCE_SNAPSHOT,
)

# --- party-balance basis -----------------------------------------------------

BASIS_OPENING = "opening"
BASIS_CURRENT = "current"
BASIS_AUTO = "auto"
VALID_PARTY_BALANCE_BASES = frozenset({BASIS_OPENING, BASIS_CURRENT, BASIS_AUTO})

#: Entities that move a party's balance after it is opened. If *any* of them is
#: in the run, the opening figure is the right one to carry, because these will
#: walk it forward themselves. If none is, the current figure is the only one
#: that will ever be true.
_BALANCE_MOVING_ENTITIES = frozenset(
    {SALE, SALE_RETURN, PAYMENT, PURCHASE_ORDER, SUPPLIER_PAYMENT}
)


def resolve_party_balance_basis(options, entities) -> str:
    """Which of the source's two party figures this run should carry.

    Explicit beats derived: an operator (or a connector's own test) can pin
    ``opening`` or ``current``. The default, ``auto``, reads it off the scope —
    which is the whole point, because the basis is a property of what is being
    imported and not a preference.
    """
    raw = (options or {}).get("party_balance_basis")
    if raw in (BASIS_OPENING, BASIS_CURRENT):
        return raw
    selected = set(entities or [])
    return BASIS_OPENING if selected & _BALANCE_MOVING_ENTITIES else BASIS_CURRENT


# --- named scopes ------------------------------------------------------------

CUSTOM = "custom"
EVERYTHING = "everything"
OPENING_POSITION = "opening_position"
CATALOGUE_ONLY = "catalogue_only"

#: The catalogue, priced and costed. The spine of every partial scope.
_CATALOGUE = (UNIT, CATEGORY, PRODUCT, VARIANT, PRODUCT_UNIT)
_PARTIES = (CUSTOMER, SUPPLIER, PARTY_BALANCE)


@dataclass(frozen=True)
class ImportScope:
    """One named answer, and the options that make it mean what it says."""

    key: str
    #: Arabic fallback. The client translates on ``key``; this is what an API
    #: consumer, a log line or an old build sees.
    label: str
    description: str
    #: ``None`` means "everything this file supports" — the free selection.
    entities: tuple[str, ...] | None
    options: dict
    #: False for the escape hatch, which is a mode rather than a preset.
    is_preset: bool = True

    def entities_for(self, available) -> tuple[str, ...]:
        """This scope's entities, closed over dependencies and intersected with
        what the source can actually produce."""
        if self.entities is None:
            return tuple(available)
        return resolve_selection(self.entities, available=available).entities

    def as_dict(self, available=None) -> dict:
        data = {
            "key": self.key,
            "label": self.label,
            "description": self.description,
            "options": dict(self.options),
            "is_preset": self.is_preset,
        }
        data["entities"] = (
            list(self.entities_for(available))
            if available is not None
            else (list(self.entities) if self.entities is not None else None)
        )
        return data


SCOPES: tuple[ImportScope, ...] = (
    ImportScope(
        key=EVERYTHING,
        label="كل شيء",
        description=(
            "الأصناف والعملاء والموردون وكامل سجل الفواتير والمدفوعات "
            "والمصروفات — كما هو في النظام القديم."
        ),
        entities=tuple(all_entity_types()),
        options={"stock_source": STOCK_SOURCE_SNAPSHOT, "party_balance_basis": BASIS_AUTO},
    ),
    ImportScope(
        key=OPENING_POSITION,
        label="نبدأ من الوضع الحالي",
        description=(
            "الأصناف بأسعارها وتكلفتها، والعملاء بما عليهم اليوم، والموردون بما "
            "لهم اليوم — بدون نقل سجل الفواتير القديم."
        ),
        entities=_CATALOGUE + _PARTIES,
        # Cost without quantity: the shop counts its own shelves on day one, but
        # the first sale must still know what the goods cost.
        options={"stock_source": STOCK_SOURCE_COST_ONLY, "party_balance_basis": BASIS_CURRENT},
    ),
    ImportScope(
        key=CATALOGUE_ONLY,
        label="الأصناف فقط",
        description="قائمة الأصناف والتصنيفات والأسعار، بدون عملاء ولا أرصدة ولا فواتير.",
        entities=_CATALOGUE,
        options={"stock_source": STOCK_SOURCE_NONE, "party_balance_basis": BASIS_AUTO},
    ),
    ImportScope(
        key=CUSTOM,
        label="تحديد يدوي",
        description="اختيار ما يُنقل بندًا بندًا.",
        entities=None,
        options={},
        is_preset=False,
    ),
)

SCOPES_BY_KEY: dict[str, ImportScope] = {scope.key: scope for scope in SCOPES}
VALID_SCOPE_KEYS = frozenset(SCOPES_BY_KEY)
#: What a run gets when nobody chooses. Unchanged from before scopes existed:
#: a selection of "everything the file has".
DEFAULT_SCOPE = EVERYTHING


#: Entities whose records name products by key. If the catalogue is being
#: filtered down to what is in stock, these cannot be in the same run: every
#: line referencing a dropped product resolves to nothing.
_PRODUCT_REFERENCING_ENTITIES = frozenset({SALE, SALE_RETURN, PURCHASE_ORDER})


def stock_filter_conflict(options, entities) -> tuple[str, ...]:
    """Entities that the in-stock-only product filter would break, if any.

    "Bring only what I still stock" and "bring my invoice history" are a
    contradiction, not a combination: the history is full of things the shop
    sold out of years ago, and each of those lines would resolve to a product
    that was deliberately not imported. One warning per line, hundreds of
    thousands of times, and an import that reports success.
    """
    if not (options or {}).get("only_stocked_products"):
        return ()
    conflicting = _PRODUCT_REFERENCING_ENTITIES & set(entities or [])
    return tuple(sorted(conflicting))


def get_scope(key) -> ImportScope | None:
    return SCOPES_BY_KEY.get(key or "")


def catalogue(available=None) -> list[dict]:
    """The scope list for the UI, entity sets resolved against one source."""
    return [scope.as_dict(available) for scope in SCOPES]


def apply_scope(key, *, entities, options, available):
    """Turn a scope choice into the (entities, options) a run should carry.

    A preset overrides both; ``custom`` (or an unknown key) passes the caller's
    own selection through. Explicit options the caller sent always win over the
    preset's, so "this scope, but snapshot the quantities" stays expressible.
    """
    scope = get_scope(key)
    options = dict(options or {})
    if scope is None or not scope.is_preset:
        return list(entities or []), options
    merged = dict(scope.options)
    merged.update(options)
    return list(scope.entities_for(available)), merged
