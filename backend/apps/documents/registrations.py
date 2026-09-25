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
        submit_effects=(
            "money_position",
            "employee_balances",
            "loan_instalments",
            "staff_purchase_settlements",
        ),
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


def _register_stock_transfer():
    from apps.inventory import documents as inventory_documents
    from apps.inventory import transfers as inventory_transfers
    from apps.inventory.models import StockTransfer

    registry.register(
        key="stock_transfer",
        label="تحويل مخزني",
        model=StockTransfer,
        number_field="transfer_number",
        # Stock, not money: moving a box across the room settles nothing, so
        # nothing dates it in the money registry.
        money_date_field=None,
        has_draft_state=True,
        # A draft transfer holds nothing. The goods only leave the source when
        # it is dispatched, which is what submitting it means.
        draft_effects=(),
        submit_effects=("stock_ledger", "valuation"),
        # Corrected by cancelling and re-sending. There is no half-measure worth
        # building: the goods are either on the road or they are not, and a
        # transfer that has begun arriving is answered with a receipt, not an
        # edit.
        corrections=(Correction.COUNTER,),
        mutable_after_submit=("note",),
        derived_fields=("status", "dispatched_at"),
        # An arrival that still stands blocks the dispatch being undone. The
        # alternative — cascading into the receipts — would reach into the far
        # end's shelves without anyone asking for that.
        blocks_cancel=(("receipts", "استلامات"),),
        cascades=(),
        progress=inventory_documents.recompute_transfer_progress,
        permissions={
            Transition.SUBMIT: "inventory.dispatch_stocktransfer",
            Transition.CANCEL: "inventory.dispatch_stocktransfer",
        },
        correction_window=None,
        reverse=inventory_transfers.reverse_transfer,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_stock_transfer_receipt():
    from apps.inventory import transfers as inventory_transfers
    from apps.inventory.models import StockTransferReceipt

    registry.register(
        key="stock_transfer_receipt",
        label="استلام تحويل",
        model=StockTransferReceipt,
        number_field=None,
        money_date_field=None,
        # Born submitted: there is no draft arrival, the same way there is no
        # draft ``PurchaseReceipt``.
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("stock_ledger", "valuation"),
        corrections=(Correction.COUNTER,),
        mutable_after_submit=("note",),
        derived_fields=(),
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "inventory.receive_stocktransfer",
            Transition.CANCEL: "inventory.receive_stocktransfer",
        },
        correction_window=None,
        reverse=inventory_transfers.reverse_transfer_receipt,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


_register_stock_transfer()
_register_stock_transfer_receipt()


def _register_consignment_agreement():
    from apps.inventory import consignment_documents
    from apps.inventory.models import ConsignmentAgreement

    registry.register(
        key="consignment_agreement",
        label="سند استلام أمانة",
        model=ConsignmentAgreement,
        number_field="number",
        # Custody, not money: signing for somebody's watch settles nothing, so
        # nothing dates it in the money registry. The payout that eventually
        # follows is its own document and carries its own date.
        money_date_field=None,
        # The terms are argued over across a counter before anybody signs, and
        # that argument is the draft.
        has_draft_state=True,
        draft_effects=(),
        # Submitting it is what starts custody: the goods come onto the shelf
        # and the shop's promise about them begins.
        submit_effects=("stock_ledger", "consignor_liability"),
        # Put right by taking the goods back and signing a new page. Never
        # amended: the clause on a signed voucher is not a figure anybody gets
        # to revise afterwards.
        corrections=(Correction.COUNTER,),
        mutable_after_submit=("notes", "expires_on"),
        derived_fields=(),
        # Refused outright once any of its units has moved — see the reversal.
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "inventory.manage_consignmentagreement",
            Transition.CANCEL: "inventory.manage_consignmentagreement",
            Transition.EDIT: "inventory.manage_consignmentagreement",
        },
        correction_window=None,
        reverse=consignment_documents.reverse_agreement,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_consignor_payout():
    from apps.inventory import consignment_documents
    from apps.inventory.models import ConsignorPayout

    registry.register(
        key="consignor_payout",
        label="سند صرف أمانة",
        model=ConsignorPayout,
        number_field="number",
        money_date_field="paid_at",
        has_draft_state=False,
        draft_effects=(),
        # Its own component in the money position, under the same
        # standalone-pay-out rule the expenses flow follows — never an expense
        # and never a supplier payment, both of which would file consignment
        # money under a category it does not belong to.
        submit_effects=("consignor_liability", "money_position", "register_payout"),
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        mutable_after_submit=("reference", "notes"),
        derived_fields=(),
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "inventory.disburse_consignment_payout",
            Transition.CANCEL: "inventory.disburse_consignment_payout",
            Transition.EDIT: "inventory.disburse_consignment_payout",
        },
        correction_window=None,
        reverse=consignment_documents.reverse_payout,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_consignment_incident():
    from apps.inventory import consignment_documents
    from apps.inventory.models import ConsignmentIncident

    registry.register(
        key="consignment_incident",
        label="محضر حادث أمانة",
        model=ConsignmentIncident,
        number_field="number",
        # Custody, not money. A claim may follow and that claim's payout is
        # dated in the money registry; the finding itself settles nothing.
        money_date_field=None,
        # Born submitted: the whole point of §6.2.2 is that the record is made
        # at the time, by whoever noticed, before anybody has decided what it
        # means. A draft would be a finding somebody could sit on.
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("consignor_liability",),
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        # The assessment and the settlement are exactly what changes after the
        # fact — that is the design, not a leak.
        mutable_after_submit=(
            "responsibility",
            "assessed_value",
            "is_assessed",
            "resolution",
            "resolved_at",
            "settlement_ref",
            "settlement_payout",
            "replacement_unit",
            "occurred_on",
            "camera",
        ),
        derived_fields=(),
        blocks_cancel=(),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "inventory.manage_consignmentincident",
            Transition.CANCEL: "inventory.manage_consignmentincident",
            Transition.EDIT: "inventory.manage_consignmentincident",
        },
        correction_window=None,
        reverse=consignment_documents.reverse_incident,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


_register_consignment_agreement()
_register_consignor_payout()
_register_consignment_incident()


def _register_customer_balance_entry():
    from apps.balances import customers as balance_customers
    from apps.balances.models import CustomerBalanceEntry

    registry.register(
        key="customer_balance_entry",
        label="قيد رصيد عميل",
        model=CustomerBalanceEntry,
        number_field="number",
        money_date_field="effective_date",
        # Born final: the balance either stands on the account or it does not.
        # A half-written opening balance is not a thing an owner can mean.
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("customer_balance",),
        # Put right by an entry the other way once anything rests on it; the
        # words are editable, and so is whose account it sits on — the one
        # change a merge of two duplicate customers has to make.
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        mutable_after_submit=("note", "customer"),
        derived_fields=(),
        # Credit that has already paid something off cannot be withdrawn: the
        # debt it settled would reopen with nothing to show why. A debt that has
        # been collected from is refused by the reversal itself, because the
        # payments hang off its carrier order rather than off the entry.
        blocks_cancel=(("applications", "رصيد مستخدم في سداد ديون العميل"),),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "balances.add_customerbalanceentry",
            Transition.CANCEL: "balances.cancel_customerbalanceentry",
            Transition.EDIT: "balances.change_customerbalanceentry",
        },
        correction_window=None,
        reverse=balance_customers.reverse_entry,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_supplier_balance_entry():
    from apps.balances import suppliers as balance_suppliers
    from apps.balances.models import SupplierBalanceEntry

    registry.register(
        key="supplier_balance_entry",
        label="قيد رصيد مورد",
        model=SupplierBalanceEntry,
        number_field="number",
        money_date_field="effective_date",
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("supplier_balance",),
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        mutable_after_submit=("note",),
        derived_fields=(),
        # A balance something has been paid against is history. A credit note
        # that has been drawn on is refused by the reversal, which is where the
        # note is.
        blocks_cancel=(("payments", "دفعات للمورد"),),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "balances.add_supplierbalanceentry",
            Transition.CANCEL: "balances.cancel_supplierbalanceentry",
            Transition.EDIT: "balances.change_supplierbalanceentry",
        },
        correction_window=None,
        reverse=balance_suppliers.reverse_entry,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


def _register_employee_balance_entry():
    from apps.balances import employees as balance_employees
    from apps.balances.models import EmployeeBalanceEntry

    registry.register(
        key="employee_balance_entry",
        label="قيد رصيد موظف",
        model=EmployeeBalanceEntry,
        number_field="number",
        money_date_field="effective_date",
        has_draft_state=False,
        draft_effects=(),
        submit_effects=("employee_balance",),
        corrections=(Correction.COUNTER, Correction.ALLOW_AFTER_SUBMIT),
        mutable_after_submit=("note",),
        derived_fields=(),
        # Cash set against it cannot be taken back, so neither can the entry.
        # A paid payroll run that settled it is refused by the reversal, which
        # also lifts it off any run not paid yet.
        blocks_cancel=(("cash_settlements", "تسوية نقدية على هذا الرصيد"),),
        cascades=(),
        progress=None,
        permissions={
            Transition.SUBMIT: "balances.add_employeebalanceentry",
            Transition.CANCEL: "balances.cancel_employeebalanceentry",
            Transition.EDIT: "balances.change_employeebalanceentry",
        },
        correction_window=None,
        reverse=balance_employees.reverse_entry,
        amend_copy=None,
        in_place_allowed=None,
        release_draft=None,
    )


_register_customer_balance_entry()
_register_supplier_balance_entry()
_register_employee_balance_entry()
