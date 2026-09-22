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

from apps.documents.guards import system_write
from apps.payments.models import Payment
from apps.sales.models import (
    Order,
    OrderAdjustment,
    OrderAdjustmentLine,
    OrderLine,
    RegisterSession,
)

from ..entity_plan import CUSTOMER, PAYMENT, SALE, SALE_RETURN, VARIANT
from .base import (
    CREATED,
    SKIPPED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoaderError,
    LoadOutcome,
    to_decimal,
)

_MONEY = Decimal("0.01")
_PAYMENT_METHODS = {choice for choice, _label in Payment.Method.choices}
#: Identifies the synthetic drawer session imported adjustments hang off.
_MIGRATION_OWNER_KEY = "migration:import"


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
                        f"سطر بيع يشير إلى صنف غير معروف {line.variant_source_key!r} — تم تجاهل السطر.",
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
            raise LoaderError("لا يوجد في الفاتورة أي سطر يمكن ربطه بصنف.", code="no_lines")

        customer_pk = resolver.resolve(CUSTOMER, record.customer_source_key)

        order = resolver.existing(Order, self.entity_type, record.source_key)
        action = UPDATED if order is not None else CREATED
        if order is not None:
            # Adjustments first: ``OrderAdjustmentLine.order_line`` is PROTECT,
            # so a sale that has had something returned cannot have its lines
            # replaced until the return goes. The return is rebuilt from the
            # source right after the sales are (ENTITY_PLAN puts SALE_RETURN
            # immediately after SALE), the same way the payments deleted on the
            # next line are.
            OrderAdjustment.objects.filter(order=order).delete()
            order.lines.all().delete()
            order.payments.all().delete()
        else:
            order = Order()
        # An import reconstructs sales that already happened, and a re-import
        # replays the same source rows over them. That is a machine rewriting
        # history, not a person editing an issued invoice — the same rule the
        # period lock follows (apps.core.period_lock: guards govern people, not
        # code). apps.documents.test_registered_types keeps the census of
        # everywhere this is allowed.
        with system_write():
            return self._write(
                order,
                action=action,
                record=record,
                resolver=resolver,
                customer_pk=customer_pk,
                line_specs=line_specs,
                issues=issues,
            )

    @staticmethod
    def _carry_receipt_number(order, record, issues):
        """Keep the number the shop's own paper copy carries, when it is free.

        The number the old system printed is the one a customer arrives holding,
        so looking a sale up by it is the point of importing sales at all.
        ``Order.save`` already steps aside for a pre-set number.

        It is checked rather than trusted: a source that starts its invoice
        series again every year — which is exactly what Fahd does at carry-over
        — hands over the same number several times, and a unique-constraint
        violation would fail the record instead of just numbering it. A taken
        number falls back to Pointy's own series, which is a cosmetic loss, and
        says so.
        """
        wanted = str(record.receipt_number or "").strip()[:32]
        if not wanted or order.receipt_number == wanted:
            return
        taken = Order.objects.filter(receipt_number=wanted)
        if order.pk:
            taken = taken.exclude(pk=order.pk)
        if taken.exists():
            issues.append(
                Issue(
                    WARNING,
                    "receipt_number_taken",
                    f"رقم الفاتورة {wanted!r} مستخدم من قبل — أُعطيت الفاتورة رقمًا جديدًا.",
                    source_key=str(record.source_key),
                )
            )
            return
        order.receipt_number = wanted

    def _write(
        self, order, *, action, record, resolver, customer_pk, line_specs, issues
    ):
        credit = record.sale_type == Order.SaleType.CREDIT
        if credit and customer_pk is None:
            # An آجل invoice is a debt, and a debt needs somebody who owes it.
            raise LoaderError(
                "فاتورة آجلة بلا عميل يتحمّل الدين.",
                code="credit_without_customer",
            )
        self._carry_receipt_number(order, record, issues)
        order.customer_id = customer_pk
        order.sale_type = Order.SaleType.CREDIT if credit else Order.SaleType.STANDARD
        # Settled at the counter, or still owed. Assigned before the lines exist
        # only so the row can be saved; the money decides it below, once the
        # total is known.
        order.status = Order.Status.OPEN if credit else Order.Status.PAID
        if credit and record.due_date is not None:
            order.due_date = record.due_date
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
        # What was actually taken against this invoice. ``None`` keeps the old
        # behaviour — the whole total — which is what a cash sale means.
        paid = order.total if record.amount_paid is None else to_decimal(record.amount_paid)
        paid = max(min(paid, order.total), Decimal("0"))
        # A credit invoice that turns out to be fully settled is PAID like any
        # other; one with anything left on it stays OPEN, which is what makes it
        # a receivable (apps.customers.receivables reads open_credit()).
        order.status = (
            Order.Status.PAID if paid >= order.total else Order.Status.OPEN
        )
        order.save(
            update_fields=[
                "subtotal",
                "discount_total",
                "total",
                "status",
                "sale_type",
                "customer",
                "due_date",
                "updated_at",
            ]
        )

        if record.occurred_at is not None:
            Order.objects.filter(pk=order.pk).update(created_at=_aware(record.occurred_at))

        method = record.payment_method if record.payment_method in _PAYMENT_METHODS else "cash"
        if paid > 0:
            payment = Payment.objects.create(order=order, method=method, amount=paid)
            if record.occurred_at is not None:
                Payment.objects.filter(pk=payment.pk).update(
                    paid_at=_aware(record.occurred_at),
                    created_at=_aware(record.occurred_at),
                )

        resolver.remember(self.entity_type, record.source_key, order)
        return LoadOutcome(action, order.pk, issues)


class PaymentLoader(BaseLoader):
    """Money received after the sale — against one invoice, or against a
    customer's account.

    The account case is the one legacy systems actually produce. A Delphi or
    FoxPro POS posts a receipt to the *party ledger* and never says which
    invoices it settles, because the ledger only has a running balance. Pointy
    has no running balance to post to: what a customer owes is the sum of their
    open آجل invoices (``apps.customers.receivables``), so a receipt has to be
    put onto invoices or it is not a receipt at all.

    Oldest first, which is what both sides assume when neither says otherwise,
    and what a shop does when it hands over cash against "the account".
    """

    entity_type = PAYMENT

    def load(self, record, resolver, *, dry_run):
        amount = to_decimal(record.amount)
        if amount <= 0:
            raise LoaderError("مبلغ الدفعة يجب أن يكون أكبر من صفر.", code="invalid_amount")
        method = record.method if record.method in _PAYMENT_METHODS else "cash"
        reference = (record.reference or f"migration:{record.source_key}")[:128]

        # A re-run replays the same receipt; clearing its rows first keeps a
        # second import from paying the same invoice twice. Keyed on the
        # reference rather than the identity map because one receipt can land on
        # several invoices, and the map holds one row per source key.
        Payment.objects.filter(external_reference=reference).delete()

        with system_write():
            if record.sale_source_key:
                return self._against_invoice(record, resolver, amount, method, reference)
            return self._against_account(record, resolver, amount, method, reference)

    def _against_invoice(self, record, resolver, amount, method, reference):
        order_pk = resolver.resolve(SALE, record.sale_source_key)
        if order_pk is None:
            raise LoaderError(
                f"دفعة تشير إلى فاتورة غير معروفة {record.sale_source_key!r}.",
                code="unresolved_sale",
            )
        payment = self._pay(order_pk, amount, method, reference, record.occurred_at)
        self._settle(order_pk)
        resolver.remember(self.entity_type, record.source_key, payment)
        return LoadOutcome(CREATED, payment.pk)

    def _against_account(self, record, resolver, amount, method, reference):
        customer_pk = resolver.resolve(CUSTOMER, record.customer_source_key)
        if customer_pk is None:
            raise LoaderError(
                f"سند قبض يشير إلى عميل غير معروف {record.customer_source_key!r}.",
                code="unresolved_customer",
            )
        orders = (
            Order.objects.open_credit()
            .filter(customer_id=customer_pk)
            .prefetch_related("payments")
            .order_by("created_at", "pk")
        )
        remaining = amount
        issues: list[Issue] = []
        first = None
        for order in orders:
            if remaining <= 0:
                break
            due = order.balance_due
            if due <= 0:
                continue
            applied = min(due, remaining)
            payment = self._pay(order.pk, applied, method, reference, record.occurred_at)
            first = first or payment
            remaining -= applied
            self._settle(order.pk)
        if remaining > 0:
            # More money than there was debt. Real, and worth saying rather than
            # inventing an invoice to absorb it: it means the customer paid
            # ahead, or that some of what they were settling predates the
            # history this file carries.
            issues.append(
                Issue(
                    WARNING,
                    "receipt_unallocated",
                    f"{remaining} of this receipt had no open invoice to settle.",
                    source_key=str(record.source_key),
                    detail={"unallocated": str(remaining), "amount": str(amount)},
                )
            )
        if first is None:
            return LoadOutcome(SKIPPED, None, issues)
        resolver.remember(self.entity_type, record.source_key, first)
        return LoadOutcome(CREATED, first.pk, issues)

    @staticmethod
    def _pay(order_pk, amount, method, reference, occurred_at):
        payment = Payment.objects.create(
            order_id=order_pk,
            method=method,
            amount=amount,
            external_reference=reference,
        )
        if occurred_at is not None:
            Payment.objects.filter(pk=payment.pk).update(
                paid_at=_aware(occurred_at), created_at=_aware(occurred_at)
            )
        return payment

    @staticmethod
    def _settle(order_pk):
        """Close an invoice the moment it is square."""
        order = Order.objects.prefetch_related("payments").get(pk=order_pk)
        if order.status == Order.Status.OPEN and order.balance_due <= 0:
            Order.objects.filter(pk=order.pk).update(status=Order.Status.PAID)


class SaleReturnLoader(BaseLoader):
    """Goods coming back off an invoice that was already imported.

    Written the way ``sales.services.record_adjustment`` writes a live one — an
    ``OrderAdjustment`` with its lines, and a negative ``Payment`` so the money
    position and the register both come down by the refund — with one
    deliberate omission: **no stock movement**. On-hand was imported as the
    source's own closing figure, which already has the returned goods back on
    the shelf. Moving stock here would put them there a second time.
    """

    entity_type = SALE_RETURN

    def load(self, record, resolver, *, dry_run):
        if not record.sale_source_key:
            # A return the connector could not place on any invoice. Reported
            # rather than dropped: the goods and the refund are real, and an
            # operator can put them right by hand once they know.
            return LoadOutcome(
                SKIPPED,
                None,
                [
                    Issue(
                        WARNING,
                        "return_without_sale",
                        "هذا المرتجع لا يشير إلى فاتورة موجودة — غالبًا أن الفاتورة التي "
                        "خرجت منها البضاعة أقدم من هذا الملف. لم يُسجَّل شيء.",
                        source_key=str(record.source_key),
                        detail={
                            "amount": str(
                                sum(
                                    (
                                        to_decimal(line.unit_price)
                                        * to_decimal(line.quantity)
                                        for line in record.lines
                                    ),
                                    Decimal("0.00"),
                                )
                            )
                        },
                    )
                ],
            )
        order_pk = resolver.resolve(SALE, record.sale_source_key)
        if order_pk is None:
            raise LoaderError(
                f"مرتجع يشير إلى فاتورة غير معروفة {record.sale_source_key!r}.",
                code="unresolved_sale",
            )
        order = Order.objects.filter(pk=order_pk).first()
        if order is None:
            raise LoaderError(
                f"مرتجع يشير إلى فاتورة غير معروفة {record.sale_source_key!r}.",
                code="unresolved_sale",
            )

        issues: list[Issue] = []
        by_variant: dict[int, list] = {}
        for line in order.lines.all():
            by_variant.setdefault(line.variant_id, []).append(line)

        specs = []
        for line in record.lines:
            variant_pk = resolver.resolve(VARIANT, line.variant_source_key)
            candidates = by_variant.get(variant_pk) if variant_pk else None
            if not candidates:
                issues.append(
                    Issue(
                        WARNING,
                        "return_line_unmatched",
                        f"الصنف المرتجع {line.variant_source_key!r} غير موجود في الفاتورة "
                        f"{order.receipt_number} — تم تجاهل السطر.",
                        source_key=str(record.source_key),
                    )
                )
                continue
            order_line = candidates[0]
            wanted = to_decimal(line.quantity)
            # Never give back more than that invoice sold. More usually means
            # the customer brought back two of something they bought one at a
            # time, and the other one belongs to an invoice we could not name —
            # so the surplus is reported rather than credited against a line
            # that never carried it.
            quantity = min(wanted, to_decimal(order_line.quantity))
            if wanted > quantity:
                issues.append(
                    Issue(
                        WARNING,
                        "return_exceeds_invoice",
                        f"{wanted} returned but invoice {order.receipt_number} "
                        f"only sold {order_line.quantity}; "
                        f"{wanted - quantity} was not credited.",
                        source_key=str(record.source_key),
                        detail={
                            "returned": str(wanted),
                            "credited": str(quantity),
                            "unit_price": str(line.unit_price),
                        },
                    )
                )
            if quantity <= 0:
                continue
            price = to_decimal(line.unit_price) or to_decimal(order_line.unit_price)
            specs.append((order_line, quantity, price))
        if not specs:
            raise LoaderError("لا يوجد في المرتجع أي سطر يطابق الفاتورة.", code="no_lines")

        existing = resolver.existing(OrderAdjustment, self.entity_type, record.source_key)
        action = UPDATED if existing is not None else CREATED
        if existing is not None:
            Payment.objects.filter(
                external_reference=f"{OrderAdjustment.AdjustmentType.RETURN}:{existing.pk}"
            ).delete()
            existing.lines.all().delete()
            existing.delete()

        amount = sum(
            ((price * quantity).quantize(_MONEY) for _line, quantity, price in specs),
            Decimal("0.00"),
        )
        method = record.refund_method if record.refund_method in _PAYMENT_METHODS else "cash"
        with system_write():
            adjustment = OrderAdjustment.objects.create(
                order=order,
                register_session=migration_register_session(),
                adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
                amount=amount,
                refund_method=method,
                cash_amount=amount if method == "cash" else Decimal("0.00"),
                reason=record.reason or "مرتجع من النظام السابق",
            )
            OrderAdjustmentLine.objects.bulk_create(
                [
                    OrderAdjustmentLine(
                        adjustment=adjustment,
                        order_line=order_line,
                        variant_id=order_line.variant_id,
                        quantity=quantity,
                        unit_price=price,
                    )
                    for order_line, quantity, price in specs
                ]
            )
            if amount > 0:
                Payment.objects.create(
                    order=order,
                    method=method,
                    amount=-amount,
                    external_reference=(
                        f"{OrderAdjustment.AdjustmentType.RETURN}:{adjustment.pk}"
                    ),
                )
            if record.occurred_at is not None:
                OrderAdjustment.objects.filter(pk=adjustment.pk).update(
                    created_at=_aware(record.occurred_at)
                )
        resolver.remember(self.entity_type, record.source_key, adjustment)
        return LoadOutcome(action, adjustment.pk, issues)


def migration_register_session():
    """The one drawer session imported adjustments belong to.

    ``OrderAdjustment.register_session`` is not nullable, and rightly so — every
    refund in a live shop came out of somebody's drawer, and the Z-Report is
    built on that being true. An imported refund came out of a drawer too; we
    just do not know whose, because the old system did not record it.

    So they are gathered into one closed session that is named for what it is,
    rather than being scattered across real cashiers' sessions (which would put
    money they never handled into their Z-Reports) or being left out (which
    would lose the refund).
    """
    session, _created = RegisterSession.objects.get_or_create(
        owner_key=_MIGRATION_OWNER_KEY,
        defaults={
            "status": RegisterSession.Status.CLOSED,
            "opening_cash": Decimal("0.00"),
            "closing_cash": Decimal("0.00"),
            "closed_at": timezone.now(),
        },
    )
    return session


def _aware(value):
    if timezone.is_naive(value):
        return timezone.make_aware(value)
    return value
