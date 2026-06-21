"""Sales loaders: sales (order + lines + payment).

Historical sales are written with **direct ORM** — never through
``apps.sales.services.create_order_with_lines`` (which applies discounts,
creates live stock movements, and would corrupt the stock that was already
imported from the source). The payment is folded in here (one payment per
invoice) so an imported order is never left "open"; the standalone payment
entity stays a stub for systems that have a separate payments table.

The original sale date is preserved by overwriting ``Order.created_at`` (which
is ``auto_now_add``) with a follow-up ``update()``.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone

from apps.payments.models import Payment
from apps.sales.models import Order, OrderLine

from ..entity_plan import CUSTOMER, PAYMENT, SALE, VARIANT
from .base import (
    CREATED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoaderError,
    LoadOutcome,
    NotImplementedLoader,
    to_decimal,
)

_MONEY = Decimal("0.01")
_PAYMENT_METHODS = {choice for choice, _label in Payment.Method.choices}


class SaleLoader(BaseLoader):
    entity_type = SALE

    def load(self, record, resolver, *, dry_run):
        issues: list[Issue] = []
        line_specs = []
        for line in record.lines:
            variant_pk = resolver.resolve(VARIANT, line.variant_source_key)
            if variant_pk is None:
                issues.append(
                    Issue(
                        WARNING,
                        "unresolved_variant",
                        f"Sale line references unknown product {line.variant_source_key!r}; skipped.",
                        source_key=str(record.source_key),
                    )
                )
                continue
            quantity = to_decimal(line.quantity)
            if quantity <= 0:
                continue
            line_specs.append(
                (
                    variant_pk,
                    quantity,
                    to_decimal(line.unit_price),
                    to_decimal(line.unit_cost),
                    to_decimal(line.discount_total),
                )
            )
        if not line_specs:
            raise LoaderError("Sale has no resolvable line items.", code="no_lines")

        customer_pk = resolver.resolve(CUSTOMER, record.customer_source_key)

        order = resolver.existing(Order, self.entity_type, record.source_key)
        action = UPDATED if order is not None else CREATED
        if order is not None:
            order.lines.all().delete()
            order.payments.all().delete()
        else:
            order = Order()
        order.customer_id = customer_pk
        order.status = Order.Status.PAID
        order.save()

        OrderLine.objects.bulk_create(
            [
                OrderLine(
                    order=order,
                    variant_id=variant_pk,
                    quantity=quantity,
                    unit_price=price,
                    unit_cost=cost,
                    discount_total=discount,
                )
                for variant_pk, quantity, price, cost, discount in line_specs
            ]
        )

        order.recalculate()
        invoice_discount = to_decimal(record.discount_total)
        if invoice_discount > 0:
            order.discount_total = min(order.discount_total + invoice_discount, order.subtotal)
            order.total = (order.subtotal - order.discount_total).quantize(_MONEY)
        order.save(
            update_fields=[
                "subtotal",
                "discount_total",
                "total",
                "status",
                "customer",
                "updated_at",
            ]
        )

        if record.occurred_at is not None:
            Order.objects.filter(pk=order.pk).update(created_at=_aware(record.occurred_at))

        method = record.payment_method if record.payment_method in _PAYMENT_METHODS else "cash"
        if order.total > 0:
            Payment.objects.create(order=order, method=method, amount=order.total)

        resolver.remember(self.entity_type, record.source_key, order)
        return LoadOutcome(action, order.pk, issues)


class PaymentLoader(NotImplementedLoader):
    """Stub. The sale loader folds in a payment per invoice; implement this only
    for source systems that keep payments in a separate table."""

    entity_type = PAYMENT


def _aware(value):
    if timezone.is_naive(value):
        return timezone.make_aware(value)
    return value
