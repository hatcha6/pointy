"""Opening balances the importer used to write as invoices and orders.

Before balances had entries of their own, an inherited balance was imported as
an unpaid آجل invoice (a customer's) or a received purchase order (a
supplier's), one line each on a service item «رصيد افتتاحي». Shops imported that
way are left as they are — nothing converts them in bulk, because most of those
documents have been collected against since, and a conversion would have to
decide what those payments now mean.

What this module does is keep a re-import from opening those parties twice:

* a re-import of the **same source** finds its own document by key and shape,
  and :func:`retire` deletes it so an entry can take its place — only while
  nothing rests on it;
* a **fresh upload** is a new source, blind to the old one's keys, so
  :func:`refuse_older_opening` looks for any such document on the party and
  refuses a second opening beside it.

Delete this module once no shop imported the earlier way is left to re-import.
"""

from __future__ import annotations

from django.db import transaction
from django.db.models import ProtectedError

from apps.documents.guards import system_write
from apps.documents.statuses import DocumentStatus
from apps.purchasing.models import PurchaseOrder
from apps.sales.models import Order, OrderAdjustment

from ..entity_plan import PURCHASE_ORDER, SALE, VARIANT
from .base import LoaderError

#: The service item those documents hang off, and the key the importer gave it.
OPENING_ITEM_KEY = "opening-balance"
OPENING_ITEM_NAME = "رصيد افتتاحي"

#: Where the earlier design kept each kind of party's opening document.
_DOCUMENTS = {
    "customer": (Order, SALE),
    "supplier": (PurchaseOrder, PURCHASE_ORDER),
}


def find(kind, key, resolver):
    """The opening document an earlier import of *this* source raised, if any.

    Recognised by its key and its shape — one line, on the opening item — rather
    than by its key alone, so a source whose balance keys happen to match one of
    its real invoices can never have that invoice taken for a placeholder.
    """
    opening_item = resolver.resolve(VARIANT, OPENING_ITEM_KEY)
    if opening_item is None:
        return None
    model, entity = _DOCUMENTS[kind]
    document = resolver.existing(model, entity, key)
    if document is None:
        return None
    variants = list(document.lines.values_list("variant_id", flat=True))
    return document if variants == [opening_item] else None


def is_voided(document) -> bool:
    if document.doc_status == DocumentStatus.CANCELLED:
        return True
    if isinstance(document, Order):
        return document.status == Order.Status.VOID
    return document.status == PurchaseOrder.Status.CANCELLED


def number_of(document) -> str:
    if isinstance(document, Order):
        return document.receipt_number
    return document.order_number


def retire(document, name):
    """Delete an old-design opening document, while nothing rests on it.

    Deleted rather than cancelled: it stands in for a number, and reversing a
    sale or a purchase would book a refund or a return that never happened.
    Anything a person has done against it since — a collection, a return, a
    receipt of goods, a supplier payment — makes it theirs, and it stays.
    """
    number = number_of(document)
    in_use = LoaderError(
        f"تعذّر نقل رصيد {name} إلى قيد رصيد: المستند الافتتاحي {number} الذي أنشأه "
        "نقل سابق عليه دفعات أو مرتجعات — بقي كما هو، ولم يُسجَّل قيد.",
        code="opening_balance_in_use",
        detail={"document": number},
    )
    if isinstance(document, Order) and (
        document.payments.exists()
        or OrderAdjustment.objects.filter(order=document).exists()
    ):
        raise in_use
    try:
        # An import artifact leaving the books, not a person editing an issued
        # document — the rule every loader that rewrites history follows.
        with transaction.atomic(), system_write():
            document.lines.all().delete()
            document.delete()
    except ProtectedError as exc:
        in_use.detail["protected"] = [
            str(obj) for obj in list(exc.protected_objects)[:5]
        ]
        raise in_use from exc


def refuse_older_opening(kind, party, name):
    """Refuse a second opening for a party an earlier import already opened.

    Reached only when this source has no document of its own for the party, so
    whatever is found came from somewhere else — most likely an earlier upload
    of the same shop, whose identity map this one cannot see.
    """
    if kind == "customer":
        candidates = Order.objects.filter(customer=party).exclude(
            status=Order.Status.VOID
        )
        number_field = "receipt_number"
    else:
        candidates = PurchaseOrder.objects.filter(supplier=party).exclude(
            status=PurchaseOrder.Status.CANCELLED
        )
        number_field = "order_number"
    number = (
        candidates.exclude(doc_status=DocumentStatus.CANCELLED)
        .filter(
            lines__variant__product__name=OPENING_ITEM_NAME,
            lines__variant__product__is_service=True,
        )
        .values_list(number_field, flat=True)
        .first()
    )
    if number is not None:
        raise LoaderError(
            f"لـ{name} رصيد افتتاحي نقله نقل سابق كمستند ({number}) — لم يُسجَّل "
            "رصيد ثانٍ فوقه.",
            code="legacy_opening_exists",
            detail={"document": number},
        )
