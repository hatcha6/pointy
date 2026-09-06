"""Every document type in the system, in one importable place.

Registrations live here rather than in the domains so that the answer to "what
is a document?" is a file you can read top to bottom, and so that adding one is
visibly a decision. The declarations themselves import their hooks from the
owning domain — purchasing knows what unwinding a delivery means; this module
only knows that it must happen.
"""

from apps.documents import registry
from apps.documents.statuses import Correction, Transition


def _register_purchase_order():
    from apps.purchasing import documents as purchasing_documents
    from apps.purchasing.models import PurchaseOrder

    registry.register(
        key="purchase_order",
        label="أمر شراء",
        model=PurchaseOrder,
        number_field="order_number",
        money_date_field="created_at",
        has_draft_state=True,
        # A draft purchase order holds nothing: the expected stock it puts on
        # the books is posted at submit, and given back at cancel.
        draft_effects=(),
        submit_effects=("expected_stock",),
        # Deliberately not AMEND yet. This shop's purchase orders are corrected
        # in place while unsettled — the affordance 87117460 built on purpose —
        # and adding an amend route nothing calls would be exactly the untested
        # cancel path this design exists to avoid. Converting the in-place route
        # to a true amendment is the next step, not a second parallel one.
        corrections=(Correction.IN_PLACE,),
        mutable_after_submit=(),
        # Fulfilment progress, maintained by the primitive and by receiving.
        derived_fields=("status", "received_at", "cancelled_total"),
        blocks_cancel=(
            ("supplier_payments", "دفعات للمورد"),
            ("supplier_credits", "أرصدة لدى المورد"),
            ("adjustments", "مرتجعات واستبدالات"),
        ),
        # A delivery undoes itself: the goods come off the shelf and the
        # expectation goes back on the order. What is left for the order's own
        # reversal is the expectation nothing ever delivered against.
        cascades=("receipts",),
        progress=purchasing_documents.recompute_progress,
        permissions={
            # The POS cash purchase submits and receives an order for a cashier
            # who holds only its own narrow code; the endpoint gates that flow,
            # so the primitive accepts it here rather than blocking a decision
            # the product already made.
            Transition.SUBMIT: (
                "purchasing.edit_draft_purchaseorder",
                "purchasing.add_pos_cash_purchase",
            ),
            Transition.CANCEL: "purchasing.cancel_purchaseorder",
            Transition.CORRECT: "purchasing.edit_draft_purchaseorder",
        },
        correction_window=None,
        reverse=purchasing_documents.reverse,
        amend_copy=None,
        in_place_allowed=purchasing_documents.in_place_allowed,
        release_draft=None,
    )


def _register_sale():
    from apps.sales import documents as sales_documents
    from apps.sales.models import Order

    registry.register(
        key="sale",
        label="فاتورة",
        model=Order,
        number_field="receipt_number",
        money_date_field="created_at",
        # A cart exists, even if only inside the checkout transaction.
        has_draft_state=True,
        # None. An order is created, priced, stocked and submitted inside one
        # checkout transaction, so from outside it has never been a draft — and
        # a draft holding stock or money is exactly what this rule refuses.
        draft_effects=(),
        submit_effects=("stock_ledger", "register_cash", "receivable"),
        # A sale is put right by giving something back, never by editing what
        # the customer was handed: the counter-document is the correction. The
        # one exception is who the sale was to — the field the returns desk
        # fixes on an unpaid debt invoice, and the reason ERPNext has
        # ``allow_on_submit`` at all.
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        mutable_after_submit=(
            "customer",
            # The legacy name for ``superseded_by``, kept in step until the
            # column goes; written only by the supersede transition's caller.
            "converted_to",
        ),
        derived_fields=("status",),
        # Nothing blocks a void: the payments a sale collected are part of what
        # voiding it gives back, not an obstacle to it.
        blocks_cancel=(),
        cascades=(),
        progress=sales_documents.recompute_progress,
        permissions={
            Transition.SUBMIT: "sales.add_order",
            Transition.CANCEL: "sales.add_order",
            Transition.EDIT: "sales.add_order",
        },
        # The cashier window lives in ``validate_order_adjustment_allowed``,
        # which the void and return paths already share; a second window here
        # would be a second answer to the same question.
        correction_window=None,
        reverse=sales_documents.reverse,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_payment():
    from apps.payments import documents as payment_documents
    from apps.payments.models import Payment

    registry.register(
        key="payment",
        label="دفعة",
        model=Payment,
        # A payment is identified by what it settles, not by a number of its own.
        number_field=None,
        money_date_field="paid_at",
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("order_balance", "register_cash", "money_position"),
        # Undone by its opposite. Never amended: the amount a customer handed
        # over is not a figure anyone gets to revise.
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        # The card-receipt validation flow attaches its evidence to a payment
        # after the fact, and the card deduper links it to a customer. Neither
        # moves money; both are exactly what ERPNext's ``allow_on_submit`` is.
        mutable_after_submit=("card", "card_receipt_data", "external_reference"),
        derived_fields=(),
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "payments.add_payment",
            # The code the delete verb used to carry, so the same people can
            # undo a payment — they just leave a trail doing it now.
            Transition.CANCEL: "payments.delete_payment",
            Transition.EDIT: "payments.change_payment",
        },
        correction_window=None,
        reverse=payment_documents.reverse,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_supplier_payment():
    from apps.purchasing import documents as purchasing_documents
    from apps.purchasing.models import SupplierPayment

    registry.register(
        key="supplier_payment",
        label="دفعة لمورد",
        model=SupplierPayment,
        number_field=None,
        money_date_field="paid_at",
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("supplier_balance", "money_position", "register_payout"),
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        # The bank's own reference for a transfer often arrives after the fact.
        mutable_after_submit=("reference", "notes"),
        derived_fields=(),
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "purchasing.add_supplierpayment",
            Transition.CANCEL: "purchasing.delete_supplierpayment",
            Transition.EDIT: "purchasing.change_supplierpayment",
        },
        correction_window=None,
        reverse=purchasing_documents.reverse_supplier_payment,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_expense():
    from apps.expenses import documents as expense_documents
    from apps.expenses.models import Expense

    registry.register(
        key="expense",
        label="مصروف",
        model=Expense,
        number_field=None,
        money_date_field="spent_at",
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("money_position", "register_payout"),
        # Correctable in place while the drawer that paid it is still open —
        # the rule the expense screen has always enforced, now the document
        # type's own condition rather than a check in one serializer.
        corrections=(Correction.IN_PLACE, Correction.ALLOW_AFTER_SUBMIT),
        # What stays editable even after the till has been counted: the words,
        # not the money. ``spent_at`` is here because moving an expense between
        # months is already guarded by the period lock, which is the guard that
        # question actually needs.
        mutable_after_submit=(
            "description",
            "notes",
            "reference",
            "category",
            "spent_at",
        ),
        derived_fields=(),
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "expenses.add_expense",
            # The code the delete verb carried, so the same people can undo an
            # expense — they just leave a record doing it now.
            Transition.CANCEL: "expenses.delete_expense",
            Transition.EDIT: "expenses.change_expense",
            Transition.CORRECT: "expenses.change_expense",
        },
        correction_window=None,
        reverse=expense_documents.reverse,
        amend_copy=None,
        in_place_allowed=expense_documents.in_place_allowed,
        release_draft=None,
    )


def _register_payroll_run():
    from apps.employees import documents as employee_documents
    from apps.employees.models import PayrollRun

    registry.register(
        key="payroll_run",
        label="مسيّر رواتب",
        model=PayrollRun,
        number_field="run_number",
        money_date_field="payment_date",
        # A run is written, checked and approved before anyone is paid; all of
        # that is the draft.
        has_draft_state=True,
        draft_effects=(),
        submit_effects=("money_position", "employee_balances", "loan_instalments"),
        corrections=(Correction.COUNTER,),
        mutable_after_submit=("notes",),
        derived_fields=("status", "voided_at", "voided_by"),
        blocks_cancel=(),
        cascades=(),
        progress=employee_documents.recompute_progress,
        permissions={
            Transition.SUBMIT: "employees.mark_payrollrun_paid",
            Transition.CANCEL: "employees.void_payrollrun",
            Transition.EDIT: "employees.change_payrollrun",
        },
        correction_window=None,
        reverse=employee_documents.reverse,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_purchase_receipt():
    from apps.purchasing import documents as purchasing_documents
    from apps.purchasing.models import PurchaseReceipt

    registry.register(
        key="purchase_receipt",
        label="استلام",
        model=PurchaseReceipt,
        number_field=None,
        # A delivery is stock, not money: nothing dates it in the money
        # registry, and nothing should.
        money_date_field=None,
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("stock_ledger", "valuation", "expected_stock"),
        # Put right by a purchase return, or by correcting the order it belongs
        # to — which unwinds and re-records the delivery around the fix.
        corrections=(Correction.COUNTER,),
        mutable_after_submit=("notes",),
        derived_fields=(),
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "purchasing.receive_purchaseorder",
            Transition.CANCEL: "purchasing.receive_purchaseorder",
        },
        correction_window=None,
        reverse=purchasing_documents.reverse_purchase_receipt,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_stock_count():
    from apps.inventory import documents as inventory_documents
    from apps.inventory.models import StockCount

    registry.register(
        key="stock_count",
        label="جرد المخزون",
        model=StockCount,
        number_field=None,
        # Stock, not money: nothing dates it in the money registry.
        money_date_field=None,
        # Counting a shelf is the draft, and it is a long one.
        has_draft_state=True,
        draft_effects=(),
        submit_effects=("stock_ledger",),
        corrections=(Correction.COUNTER,),
        mutable_after_submit=("note",),
        derived_fields=("status", "applied_at", "applied_by"),
        blocks_cancel=(),
        cascades=(),
        progress=inventory_documents.recompute_progress,
        permissions={
            Transition.SUBMIT: "inventory.apply_stockcount",
            # Undoing an applied count moves stock, so it takes the permission
            # that applying it took...
            Transition.CANCEL: "inventory.apply_stockcount",
            # ...while abandoning a half-walked shelf is the counter's own job.
            Transition.DISCARD: "inventory.change_stockcount",
        },
        correction_window=None,
        reverse=inventory_documents.reverse,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


_register_stock_count()
_register_payroll_run()
_register_purchase_receipt()
_register_purchase_order()
_register_sale()
_register_payment()
_register_supplier_payment()
_register_expense()
