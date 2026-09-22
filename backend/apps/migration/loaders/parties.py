"""Party balances — what each customer owes, and what the shop owes each supplier.

Pointy has no standalone "balance" field on a customer or a supplier, and that
is deliberate: a receivable is the sum of the آجل invoices nobody has settled
yet, and a payable is the sum of the unpaid orders. Writing a number somewhere
would give the same dinars two authorities, and the one in the field would be
the one nobody ever updates.

So an inherited balance is imported as the document that makes it true: a credit
invoice the customer has not paid, or a received order the shop has not paid.
Both are raised against a service product — "رصيد افتتاحي" — which keeps no
stock, so carrying a debt on it can never move inventory or cost of sales.

This loader **delegates** to :class:`SaleLoader` and
:class:`PurchaseOrderLoader` rather than writing orders itself. Those two know
about register sessions, the document freeze, payment folding and re-import
rewriting, all of it proved against a real shop's books; a second implementation
of "write an invoice" would be a second set of those rules to keep in step.

The identity map keys the resulting order under ``sale``/``purchase_order``,
which is what makes the scopes interchangeable: a shop imported on the opening
position and later re-imported with its full history updates the very same
opening invoice instead of growing a duplicate beside it.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

from django.db.models import ProtectedError
from django.utils import timezone

from apps.catalog.models import Product
from apps.documents.guards import system_write
from apps.purchasing.models import PurchaseOrder
from apps.sales.models import Order, OrderAdjustment

from .. import canonical
from ..entity_plan import (
    CUSTOMER,
    PARTY_BALANCE,
    PRODUCT,
    PURCHASE_ORDER,
    SALE,
    SUPPLIER,
    VARIANT,
)
from .base import (
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
from .purchasing import PurchaseOrderLoader
from .sales import SaleLoader

KIND_CUSTOMER = "customer"
KIND_SUPPLIER = "supplier"

#: Source key of the service product balances are raised against. Shared with
#: the connectors that already emit it (KASS does), so the product a full import
#: creates and the one a balances-only import falls back to are the same row.
OPENING_PRODUCT_KEY = "opening-balance"
OPENING_PRODUCT_NAME = "رصيد افتتاحي"
OPENING_PRODUCT_DESCRIPTION = (
    "بند فني يحمل أرصدة العملاء والموردين المرحّلة من النظام السابق. لا يُباع ولا يُشترى."
)

_MONEY = Decimal("0.01")


class PartyBalanceLoader(BaseLoader):
    entity_type = PARTY_BALANCE

    def __init__(self):
        self._sales = SaleLoader()
        self._purchases = PurchaseOrderLoader()

    def load(self, record, resolver, *, dry_run):
        amount = to_decimal(record.amount).quantize(_MONEY)
        kind = clean_str(record.party_kind) or KIND_CUSTOMER
        if kind not in (KIND_CUSTOMER, KIND_SUPPLIER):
            raise LoaderError(
                f"نوع طرف غير معروف {record.party_kind!r}.", code="unknown_party_kind"
            )

        if amount <= 0:
            # A party who is square is not an error and not a document — but a
            # document may already exist, raised by an earlier run on a
            # different basis, and leaving it would double what they owe.
            return self._withdraw(record, kind, resolver, dry_run=dry_run)

        party_entity = CUSTOMER if kind == KIND_CUSTOMER else SUPPLIER
        if resolver.resolve(party_entity, record.party_source_key) is None:
            raise LoaderError(
                f"رصيد يشير إلى {kind} غير معروف {record.party_source_key!r}.",
                code="unresolved_party",
                detail={"party_name": clean_str(record.party_name)},
            )

        # Creates (and registers) the balance-carrying product if this run's
        # scope left products out entirely.
        self._opening_variant(resolver, dry_run=dry_run)
        occurred_at = record.as_of or (timezone.now() - timedelta(days=1))

        if kind == KIND_CUSTOMER:
            outcome = self._sales.load(
                self._as_sale(record, amount, occurred_at),
                resolver,
                dry_run=dry_run,
            )
        else:
            outcome = self._purchases.load(
                self._as_purchase(record, amount, occurred_at),
                resolver,
                dry_run=dry_run,
            )
        return LoadOutcome(outcome.action, outcome.target_pk, outcome.issues)

    def _withdraw(self, record, kind, resolver, *, dry_run):
        """Remove an opening document this run no longer calls for.

        This is what makes the scopes safe to change your mind about. A shop
        imported on today's balances and re-imported later with its full history
        would otherwise owe both: the opening invoice raised for the current
        figure, plus every invoice that produced it. Deleted rather than
        cancelled because the document is an import artifact standing in for a
        number, and the number is now zero — there is nothing for a reversal to
        be a reversal *of*.
        """
        entity = SALE if kind == KIND_CUSTOMER else PURCHASE_ORDER
        model = Order if kind == KIND_CUSTOMER else PurchaseOrder
        existing = resolver.existing(model, entity, record.source_key)
        if existing is None:
            return LoadOutcome(SKIPPED, None)
        try:
            with system_write():
                if kind == KIND_CUSTOMER:
                    # OrderAdjustmentLine.order_line is PROTECT, so a return
                    # against this invoice has to go before its lines can.
                    OrderAdjustment.objects.filter(order=existing).delete()
                    existing.payments.all().delete()
                existing.lines.all().delete()
                existing.delete()
        except ProtectedError as exc:
            # Something real was hung off the placeholder — a receipt booked
            # against the opening order, most likely, which means a person has
            # since treated it as a genuine document. Refusing loudly is the
            # only safe answer: deleting it would take their work with it, and
            # leaving it silently would double what this party owes.
            raise LoaderError(
                f"تعذّر حذف المستند الافتتاحي لـ"
                f"{record.party_name or record.party_source_key} لأن هناك "
                f"مستندات مرتبطة به.",
                code="opening_balance_in_use",
                detail={"protected": [str(obj) for obj in list(exc.protected_objects)[:5]]},
            ) from exc
        return LoadOutcome(
            UPDATED,
            None,
            [
                Issue(
                    WARNING,
                    "opening_balance_withdrawn",
                    f"{record.party_name or record.party_source_key} لم يعد له رصيد هنا — "
                    "حُذف المستند الافتتاحي الذي أنشأه نقل سابق.",
                    source_key=str(record.source_key),
                )
            ],
        )

    # --- the documents ---------------------------------------------------
    def _as_sale(self, record, amount, occurred_at):
        """An آجل invoice, issued and untouched: the customer owes ``amount``."""
        return canonical.CanonicalSale(
            source_key=str(record.source_key),
            customer_source_key=str(record.party_source_key),
            status="open",
            sale_type="credit",
            amount_paid=Decimal("0"),
            payment_method="cash",
            occurred_at=occurred_at,
            lines=[
                canonical.CanonicalSaleLine(
                    variant_source_key=OPENING_PRODUCT_KEY,
                    quantity=Decimal("1"),
                    unit_price=amount,
                    unit_cost=Decimal("0"),
                )
            ],
            raw=dict(record.raw or {}) | {"opening_balance_for": clean_str(record.party_name)},
        )

    def _as_purchase(self, record, amount, occurred_at):
        """A received, unpaid order: the shop owes ``amount``."""
        return canonical.CanonicalPurchaseOrder(
            source_key=str(record.source_key),
            supplier_source_key=str(record.party_source_key),
            status="received",
            supplier_invoice_number=OPENING_PRODUCT_NAME,
            occurred_at=occurred_at,
            lines=[
                canonical.CanonicalPurchaseLine(
                    variant_source_key=OPENING_PRODUCT_KEY,
                    quantity=Decimal("1"),
                    unit_cost=amount,
                )
            ],
            raw=dict(record.raw or {}) | {"opening_balance_for": clean_str(record.party_name)},
        )

    # --- the product the documents hang off ------------------------------
    def _opening_variant(self, resolver, *, dry_run):
        """The service product's default variant, created on demand.

        A connector may already have emitted it (and then the identity map
        resolves it, which is the common path on a full import). When products
        are out of the run's scope entirely — the case this whole entity exists
        for — there is nothing to resolve, so it is created here. Either way it
        is one row, under one source key.
        """
        variant_pk = resolver.resolve(VARIANT, OPENING_PRODUCT_KEY)
        if variant_pk is not None:
            return variant_pk

        product = resolver.existing(Product, PRODUCT, OPENING_PRODUCT_KEY)
        if product is None:
            product = Product.objects.filter(
                name=OPENING_PRODUCT_NAME, is_service=True
            ).first()
        if product is None:
            product = Product(
                name=OPENING_PRODUCT_NAME,
                description=OPENING_PRODUCT_DESCRIPTION,
                # A service keeps no stock and is skipped by the stock loader.
                is_service=True,
                is_active=True,
            )
            product.save()
        resolver.remember(PRODUCT, OPENING_PRODUCT_KEY, product)

        variant = product.ensure_default_variant(
            name="",
            sku="",
            barcode="",
            unit_price=Decimal("0"),
            is_active=True,
        )
        if variant is None:
            raise LoaderError(
                "تعذّر تجهيز صنف «رصيد افتتاحي» الذي تُحمَّل عليه الأرصدة.",
                code="no_opening_variant",
            )
        resolver.remember(VARIANT, OPENING_PRODUCT_KEY, variant)
        return variant.pk

