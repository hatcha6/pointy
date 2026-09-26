"""Party balances — what each customer owes, and what the shop owes each supplier.

An inherited balance is a fact about a party's account on the day the shop
started keeping its books here, and Pointy has a document for exactly that: the
opening balance entry of ``apps.balances``. Each balance is written as one,
through that app's own services, so an imported balance obeys every rule a typed
one does — one live opening per account, never dated in the future or inside a
closed period, numbered from the same gapless series, and retracted only by
cancelling it while nothing has been settled against it.

The record's sign says which way it runs (``CanonicalPartyBalance.amount``):

* a customer who owes the shop — a debt, carried by a non-sale
  ``ACCOUNT_ENTRY`` order so the till can collect it and the history's own
  receipts can settle it (``PaymentLoader``);
* a customer the shop owes — account credit, spent on what they owe at their
  next collection;
* a supplier the shop owes — a payable the supplier's payments settle;
* a supplier who owes the shop — a supplier credit note.

None of it is a sale or a purchase. The design this replaces raised an unpaid
آجل invoice, or a received order, against a service item «رصيد افتتاحي»: every
inherited debt landed in the import day's sales and purchases, and a balance
running the other way could not be written at all, so credit was dropped. Shops
imported that way are left as they are; ``legacy_openings`` keeps a re-import
from opening them twice.

Re-running
----------
The entry is kept in the identity map under ``customer_balance_entry`` or
``supplier_balance_entry`` and the record's own source key, so a re-run finds the
entry it wrote:

* the same figure — left exactly as it is;
* a different figure — which is what switching scope does, from today's balance
  to the opening one plus the history — the entry is cancelled and a new one is
  written in its place;
* zero — the entry is withdrawn, so a shop imported on today's balances and later
  re-imported with its history does not owe both.

Cancelling goes through ``apps.documents``, so it is refused while anything
rests on the entry — a collection against the debt, credit already spent, a
supplier payment against it. The record then fails loudly and nothing about the
party changes (``opening_balance_in_use``). An entry a *person* cancelled stays
cancelled: an import does not overrule the owner with the figure they rejected.

A dry run writes all of it for real inside the engine's rolled-back transaction;
the entry numbers roll back with it (the series is a counter row).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from decimal import Decimal

from django.utils import timezone
from rest_framework import serializers

from apps.balances import customers as customer_balances
from apps.balances import suppliers as supplier_balances
from apps.balances.models import (
    BalanceEntry,
    CustomerBalanceEntry,
    SupplierBalanceEntry,
)
from apps.core.period_lock import PeriodLocked
from apps.customers.models import Customer
from apps.documents import services as documents
from apps.documents.errors import DocumentBlocked
from apps.documents.statuses import DocumentStatus
from apps.purchasing.models import Supplier

from ..entity_plan import CUSTOMER, PARTY_BALANCE, SUPPLIER
from . import legacy_openings
from .base import (
    CREATED,
    SKIPPED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoaderError,
    LoadOutcome,
    clean_str,
    to_decimal,
)

KIND_CUSTOMER = "customer"
KIND_SUPPLIER = "supplier"

#: The identity-map entity types an entry is registered under — the documents
#: registry's own names for the two kinds of entry.
CUSTOMER_ENTRY = "customer_balance_entry"
SUPPLIER_ENTRY = "supplier_balance_entry"

#: What every imported entry says about itself on the party's statement.
IMPORT_NOTE = "رصيد منقول من النظام السابق."
_REPLACED = "أُعيد نقل الرصيد من النظام السابق بمبلغ مختلف."
_WITHDRAWN = "لم يعد للطرف رصيد في آخر نقل من النظام السابق."

Direction = BalanceEntry.Direction
Kind = BalanceEntry.Kind

_MONEY = Decimal("0.01")


@dataclass(frozen=True)
class _Side:
    """What differs between a customer's account and a supplier's."""

    kind: str
    label: str
    party_entity: str
    party_model: type
    entry_model: type
    identity: str
    #: The direction a positive amount means on this side.
    usual: str

    def direction(self, amount: Decimal) -> str:
        if amount > 0:
            return self.usual
        if self.usual == Direction.THEY_OWE_US:
            return Direction.WE_OWE_THEM
        return Direction.THEY_OWE_US


_SIDES = {
    KIND_CUSTOMER: _Side(
        kind=KIND_CUSTOMER,
        label="عميل",
        party_entity=CUSTOMER,
        party_model=Customer,
        entry_model=CustomerBalanceEntry,
        identity=CUSTOMER_ENTRY,
        usual=Direction.THEY_OWE_US,
    ),
    KIND_SUPPLIER: _Side(
        kind=KIND_SUPPLIER,
        label="مورّد",
        party_entity=SUPPLIER,
        party_model=Supplier,
        entry_model=SupplierBalanceEntry,
        identity=SUPPLIER_ENTRY,
        usual=Direction.WE_OWE_THEM,
    ),
}


class PartyBalanceLoader(BaseLoader):
    entity_type = PARTY_BALANCE

    def load(self, record, resolver, *, dry_run):
        amount = to_decimal(record.amount).quantize(_MONEY)
        kind = clean_str(record.party_kind) or KIND_CUSTOMER
        side = _SIDES.get(kind)
        if side is None:
            raise LoaderError(
                f"نوع طرف غير معروف {record.party_kind!r}.", code="unknown_party_kind"
            )
        name = clean_str(record.party_name) or str(record.party_source_key)
        key = str(record.source_key)

        entry = resolver.existing(side.entry_model, side.identity, key)
        if entry is not None and entry.doc_status == DocumentStatus.CANCELLED:
            if entry.cancelled_by_id is not None:
                return _left_retracted(key, name, entry.number, amount)
            # Withdrawn by an earlier run, not by a person: a balance the
            # source carries again gets an entry of its own.
            entry = None

        legacy = legacy_openings.find(side.kind, key, resolver)
        if legacy is not None and legacy_openings.is_voided(legacy):
            return _left_retracted(key, name, legacy_openings.number_of(legacy), amount)

        if amount == 0:
            return self._withdraw(key, name, entry, legacy)

        party = _party(side, record, resolver, name)
        direction = side.direction(amount)
        effective_date = _effective_date(record.as_of)
        if record.as_of is None and entry is not None:
            # A source that cannot date a balance does not move it either:
            # "the day before the import" is another day on every re-run.
            effective_date = entry.effective_date
        if (
            entry is not None
            and legacy is None
            and entry.kind == Kind.OPENING
            and entry.direction == direction
            and entry.amount == abs(amount)
            and entry.effective_date == effective_date
        ):
            return LoadOutcome(UPDATED, entry.pk)

        if legacy is not None:
            legacy_number = legacy_openings.number_of(legacy)
            legacy_openings.retire(legacy, name)
        elif entry is None:
            legacy_openings.refuse_older_opening(side.kind, party, name)
        if entry is not None:
            _cancel(entry, name, reason=_REPLACED)
        created = _create(
            side,
            party,
            direction=direction,
            amount=abs(amount),
            effective_date=effective_date,
            name=name,
        )
        resolver.remember(side.identity, key, created)

        issues = []
        if legacy is not None:
            issues.append(
                Issue(
                    WARNING,
                    "opening_balance_converted",
                    f"رصيد {name} كان منقولًا كمستند افتتاحي ({legacy_number}) يُحسب "
                    f"مبيعات أو مشتريات — حُذف المستند وسُجّل الرصيد قيدًا "
                    f"({created.number}).",
                    source_key=key,
                    detail={"removed": legacy_number, "created": created.number},
                )
            )
        if entry is not None:
            issues.append(
                Issue(
                    WARNING,
                    "opening_balance_replaced",
                    f"تغيّر رصيد {name} في هذا النقل: أُلغي القيد {entry.number} "
                    f"({_describe(entry.direction, entry.amount)}) وسُجّل بدلًا منه "
                    f"{created.number} ({_describe(created.direction, created.amount)}).",
                    source_key=key,
                    detail={"cancelled": entry.number, "created": created.number},
                )
            )
        action = CREATED if entry is None and legacy is None else UPDATED
        return LoadOutcome(action, created.pk, issues)

    def _withdraw(self, key, name, entry, legacy):
        """Retract what an earlier run wrote for a party who is now square.

        This is what makes the scopes safe to change your mind about. A shop
        imported on today's balances and re-imported later with its full history
        would otherwise owe both: the entry written for today's figure, plus
        every invoice that produced it. Cancelled rather than deleted, like any
        entry — its number stays accounted for and its trail says why.
        """
        issues = []
        if legacy is not None:
            number = legacy_openings.number_of(legacy)
            legacy_openings.retire(legacy, name)
            issues.append(
                Issue(
                    WARNING,
                    "opening_balance_withdrawn",
                    f"{name} لم يعد له رصيد في هذا النقل — حُذف المستند الافتتاحي "
                    f"{number} الذي أنشأه نقل سابق.",
                    source_key=key,
                )
            )
        if entry is not None:
            _cancel(entry, name, reason=_WITHDRAWN)
            issues.append(
                Issue(
                    WARNING,
                    "opening_balance_withdrawn",
                    f"{name} لم يعد له رصيد في هذا النقل — أُلغي قيد الرصيد "
                    f"{entry.number} الذي سجّله نقل سابق.",
                    source_key=key,
                )
            )
        if not issues:
            return LoadOutcome(SKIPPED, None)
        return LoadOutcome(UPDATED, None, issues)


# --- writing and retracting entries -----------------------------------------


def _create(side, party, *, direction, amount, effective_date, name):
    """One opening entry, through the balances app's own service."""
    fields = {
        "kind": Kind.OPENING,
        "direction": direction,
        "amount": amount,
        "effective_date": effective_date,
        "note": IMPORT_NOTE,
    }
    try:
        if side.kind == KIND_CUSTOMER:
            return customer_balances.create_customer_entry(customer=party, **fields)
        return supplier_balances.create_supplier_entry(supplier=party, **fields)
    except PeriodLocked as exc:
        raise _period_locked(name, exc) from exc
    except serializers.ValidationError as exc:
        if _code_of(exc) == "opening_balance_exists":
            number = (
                side.entry_model.objects.live()
                .filter(**{side.kind: party}, kind=Kind.OPENING)
                .values_list("number", flat=True)
                .first()
            )
            raise LoaderError(
                f"لـ{name} رصيد افتتاحي مسجّل في دفتر ({number}) — لم يُسجَّل رصيد "
                "ثانٍ فوقه. ألغِ القيد الموجود أو سجّل الفرق تسوية.",
                code="opening_balance_exists",
                detail={"number": number},
            ) from exc
        raise LoaderError(
            f"تعذّر تسجيل رصيد {name}: {_plain(exc.detail)}",
            code="invalid_balance",
        ) from exc


def _cancel(entry, name, *, reason):
    """Cancel an entry an earlier run wrote — refused, with nothing changed,
    once anything has been settled against it."""
    try:
        documents.cancel(entry, reason=reason)
    except DocumentBlocked as exc:
        raise LoaderError(
            f"تعذّر تغيير رصيد {name}: القيد {entry.number} الذي سجّله نقل سابق "
            "سُدِّد منه أو استُخدم منذ ذلك الحين — لم يُغيَّر شيء. صحّح الفرق بقيد "
            "تسوية.",
            code="opening_balance_in_use",
            detail={"number": entry.number, "blockers": exc.blockers},
        ) from exc
    except PeriodLocked as exc:
        raise _period_locked(name, exc) from exc


def _period_locked(name, exc):
    return LoaderError(
        f"رصيد {name} يقع في فترة مقفلة (حتى {exc.locked_through.isoformat()}) — "
        "لم يُسجَّل ولم يُغيَّر.",
        code="period_locked",
        detail={
            "date": exc.when.isoformat(),
            "locked_through": exc.locked_through.isoformat(),
        },
    )


def _left_retracted(key, name, number, amount):
    """A document an earlier run wrote, which a person has since retracted."""
    if amount == 0:
        return LoadOutcome(SKIPPED, None)
    return LoadOutcome(
        SKIPPED,
        None,
        [
            Issue(
                WARNING,
                "opening_balance_retracted",
                f"رصيد {name} الذي نقله نقل سابق ({number}) أُلغي في دفتر — "
                "لم يُعَد تسجيله.",
                source_key=key,
                detail={"number": number},
            )
        ],
    )


# --- small readers ------------------------------------------------------------


def _party(side, record, resolver, name):
    pk = resolver.resolve(side.party_entity, record.party_source_key)
    party = side.party_model.objects.filter(pk=pk).first() if pk is not None else None
    if party is None:
        raise LoaderError(
            f"رصيد يشير إلى {side.label} غير معروف {record.party_source_key!r}.",
            code="unresolved_party",
            detail={"party_name": name},
        )
    return party


def _effective_date(value) -> date:
    """The day the balance applies from. A source that cannot say is dated the
    day before the import, so the debt does not read as incurred this morning —
    on the day reports and the period lock slice by (``timezone.localdate``),
    not the shop's own, which runs two hours ahead of it after midnight."""
    if value is None:
        return timezone.localdate() - timedelta(days=1)
    if isinstance(value, datetime):
        if timezone.is_aware(value):
            value = timezone.localtime(value)
        return value.date()
    return value


def _describe(direction, amount) -> str:
    return f"عليه {amount}" if direction == Direction.THEY_OWE_US else f"له {amount}"


def _code_of(exc) -> str:
    detail = exc.detail if isinstance(exc.detail, dict) else {}
    code = detail.get("code", "")
    if isinstance(code, list):
        code = code[0] if code else ""
    return str(code)


def _plain(detail) -> str:
    """A refusal's messages as one line, without DRF's wrappers around them."""
    if isinstance(detail, dict):
        return " ".join(
            _plain(value) for key, value in detail.items() if key != "code"
        )
    if isinstance(detail, (list, tuple)):
        return " ".join(_plain(value) for value in detail)
    return str(detail)
