"""What reports exist, who may run them, and what each one leads with.

Three things used to be decided in three different places and drift apart: the
backend's permission gate, the client's list of tiles, and the PDF's choice of
which figures to put in the header grid (it took the first eight, so a report
with ten lost two at random). All three now read this table.

``headline`` is the deliberate answer to that last one. A report's headline
figures are an editorial choice — the two or three numbers an owner should read
first — not the first N keys of a dictionary.
"""

from dataclasses import dataclass, field

from apps.core.roles import user_has_full_visibility

from .models import ReportRun


@dataclass(frozen=True)
class ReportDefinition:
    key: str
    category: str
    permissions: tuple[str, ...]
    #: Figures the client leads with, in order. Everything else still prints in
    #: the summary table; this only decides what is promoted.
    headline: tuple[str, ...] = ()
    default_output_format: str = ReportRun.OutputFormat.PDF
    #: Parameters this report cannot be built without (a statement needs a
    #: party). Validated before anything is queried.
    required_params: tuple[str, ...] = ()
    #: A report whose subject is a position at a moment rather than activity
    #: over a window — the period selects the *as-of* date, not a range.
    point_in_time: bool = False
    #: Reports assembled from other reports. Listed so the pack can build only
    #: the parts the user may see, and say which it left out.
    composed_of: tuple[str, ...] = field(default=())

    def is_allowed(self, user):
        # ``None`` is the scheduler — see apps.reports.builders.scope._scoped.
        if user is None or user_has_full_visibility(user):
            return True
        return all(user.has_perm(permission) for permission in self.permissions)


ReportType = ReportRun.ReportType

REPORT_DEFINITIONS = {
    ReportType.SALES_SUMMARY: ReportDefinition(
        key=ReportType.SALES_SUMMARY,
        category="sales",
        permissions=("sales.view_order",),
        headline=("net_sales", "gross_profit", "profit_margin_percent", "items_sold"),
    ),
    ReportType.PAYMENT_METHODS: ReportDefinition(
        key=ReportType.PAYMENT_METHODS,
        category="payments",
        permissions=("payments.view_payment",),
        headline=("payment_total", "commission_total", "payment_count"),
    ),
    ReportType.REGISTER_CLOSURE: ReportDefinition(
        key=ReportType.REGISTER_CLOSURE,
        category="cash",
        permissions=("sales.view_registersession",),
        headline=("session_count", "variance_total", "short_session_count"),
    ),
    ReportType.INVENTORY_STATUS: ReportDefinition(
        key=ReportType.INVENTORY_STATUS,
        category="inventory",
        permissions=("inventory.view_stockitem",),
        headline=("cost_stock_value", "retail_stock_value", "low_stock_count"),
        point_in_time=True,
    ),
    ReportType.STOCK_MOVEMENTS: ReportDefinition(
        key=ReportType.STOCK_MOVEMENTS,
        category="inventory",
        permissions=("inventory.view_stockmovement",),
        headline=("movement_count", "quantity_moved", "shrinkage_total"),
    ),
    ReportType.PURCHASING_SUMMARY: ReportDefinition(
        key=ReportType.PURCHASING_SUMMARY,
        category="purchasing",
        permissions=("purchasing.view_purchaseorder",),
        headline=("purchase_total", "purchase_order_count", "open_order_count"),
    ),
    ReportType.REORDER_ITEMS: ReportDefinition(
        key=ReportType.REORDER_ITEMS,
        category="inventory",
        permissions=("inventory.view_stockitem",),
        headline=("reorder_item_count", "out_of_stock_count", "suggested_units"),
        point_in_time=True,
    ),
    ReportType.PAYROLL_SUMMARY: ReportDefinition(
        key=ReportType.PAYROLL_SUMMARY,
        category="employees",
        permissions=("employees.view_payrollrun",),
        headline=("salary_expense", "paid_total", "pending_total"),
    ),
    ReportType.PROFIT_COSTS: ReportDefinition(
        key=ReportType.PROFIT_COSTS,
        category="sales",
        permissions=("sales.view_order", "employees.view_payrollrun"),
        headline=(
            "net_sales",
            "gross_profit",
            "operating_expense_total",
            "net_operating_profit",
        ),
    ),
    ReportType.RECEIVABLES_AGING: ReportDefinition(
        key=ReportType.RECEIVABLES_AGING,
        category="receivables",
        permissions=("sales.view_order", "customers.view_customer"),
        headline=("receivable_total", "overdue_total", "customer_count"),
        point_in_time=True,
    ),
    ReportType.PAYABLES_AGING: ReportDefinition(
        key=ReportType.PAYABLES_AGING,
        category="payables",
        permissions=("purchasing.view_purchaseorder", "purchasing.view_supplier"),
        headline=("payable_total", "overdue_total", "supplier_count"),
        point_in_time=True,
    ),
    ReportType.CUSTOMER_STATEMENT: ReportDefinition(
        key=ReportType.CUSTOMER_STATEMENT,
        category="receivables",
        permissions=("sales.view_order", "customers.view_customer"),
        headline=("closing_balance", "invoiced_total", "received_total"),
        required_params=("customer_id",),
    ),
    ReportType.SUPPLIER_STATEMENT: ReportDefinition(
        key=ReportType.SUPPLIER_STATEMENT,
        category="payables",
        permissions=("purchasing.view_purchaseorder", "purchasing.view_supplier"),
        headline=("closing_balance", "invoiced_total", "paid_total"),
        required_params=("supplier_id",),
    ),
    ReportType.CASH_POSITION: ReportDefinition(
        key=ReportType.CASH_POSITION,
        category="cash",
        permissions=("treasury.view_moneyaccount",),
        headline=("closing_total", "opening_total", "counted_variance_total"),
    ),
    ReportType.EXPENSE_BREAKDOWN: ReportDefinition(
        key=ReportType.EXPENSE_BREAKDOWN,
        category="expenses",
        permissions=("expenses.view_expense",),
        headline=("expense_total", "category_count", "expense_count"),
    ),
    ReportType.PRODUCT_MARGIN: ReportDefinition(
        key=ReportType.PRODUCT_MARGIN,
        category="sales",
        permissions=("sales.view_order",),
        headline=("revenue_total", "profit_total", "margin_percent"),
    ),
    ReportType.DISCOUNT_AUDIT: ReportDefinition(
        key=ReportType.DISCOUNT_AUDIT,
        category="sales",
        permissions=("sales.view_order",),
        headline=("discount_total", "refund_total", "void_total"),
    ),
    ReportType.SALES_BY_STAFF: ReportDefinition(
        key=ReportType.SALES_BY_STAFF,
        category="sales",
        permissions=("sales.view_order",),
        headline=("net_sales", "staff_count", "busiest_hour"),
    ),
    ReportType.MONTH_END_PACK: ReportDefinition(
        key=ReportType.MONTH_END_PACK,
        category="close",
        # The pack is the shop-wide close document, so it is gated on the
        # reporting permission itself rather than on any one of the sources it
        # assembles: a cashier who may read their own orders has no business
        # holding the month's payroll, payables and cash position in one file.
        permissions=("reports.view_reportrun",),
        headline=("net_sales", "gross_profit", "net_operating_profit", "closing_cash"),
        composed_of=(
            ReportType.PROFIT_COSTS,
            ReportType.CASH_POSITION,
            ReportType.RECEIVABLES_AGING,
            ReportType.PAYABLES_AGING,
            ReportType.INVENTORY_STATUS,
            ReportType.EXPENSE_BREAKDOWN,
            ReportType.REGISTER_CLOSURE,
        ),
    ),
    ReportType.BALANCE_SHEET: ReportDefinition(
        key=ReportType.BALANCE_SHEET,
        category="close",
        # What the whole shop is worth, on one page: stock, every till and
        # bank, every debt in both directions and the staff's. Gated like the
        # month-end pack, on the reporting permission itself, because it is a
        # shop-wide close document rather than a view of any one of its lines.
        permissions=("reports.view_reportrun",),
        headline=("net_position", "total_assets", "total_liabilities", "zakat_due"),
    ),
    ReportType.UNIT_AGING: ReportDefinition(
        key=ReportType.UNIT_AGING,
        category="inventory",
        permissions=("inventory.view_stockunit",),
        headline=("unit_count", "capital_on_shelf", "stale_unit_count", "oldest_days"),
        # What is on the shelf *now*, and for how long. A window would answer a
        # question nobody asks: an article's age is measured from today.
        point_in_time=True,
    ),
    ReportType.UNIT_MARGIN: ReportDefinition(
        key=ReportType.UNIT_MARGIN,
        category="inventory",
        # Reads what every article cost, so it takes the cost permission rather
        # than the list one: this report *is* the cost mask's subject matter.
        permissions=("inventory.view_stockunit_cost",),
        headline=("units_sold", "revenue", "gross_profit", "loss_making_units"),
    ),
    ReportType.UNIT_LEDGER: ReportDefinition(
        key=ReportType.UNIT_LEDGER,
        category="inventory",
        permissions=("inventory.view_stockunit",),
        headline=("status", "spell_count", "event_count"),
        required_params=("code",),
        point_in_time=True,
    ),
    ReportType.CONSIGNMENT_LEDGER: ReportDefinition(
        key=ReportType.CONSIGNMENT_LEDGER,
        category="inventory",
        permissions=("inventory.view_consignment_liability",),
        headline=(
            "consignor_payable",
            "shop_commission",
            "custody_unit_count",
            "custody_declared_value",
        ),
    ),
}


def report_catalog_for_user(user):
    return [
        {
            "key": definition.key,
            "category": definition.category,
            "default_output_format": definition.default_output_format,
            "permissions": definition.permissions,
            "headline": definition.headline,
            "required_params": definition.required_params,
            "point_in_time": definition.point_in_time,
        }
        for definition in REPORT_DEFINITIONS.values()
        if definition.is_allowed(user)
    ]


def allowed_definitions(user, keys):
    return [
        REPORT_DEFINITIONS[key]
        for key in keys
        if key in REPORT_DEFINITIONS and REPORT_DEFINITIONS[key].is_allowed(user)
    ]


__all__ = [
    "REPORT_DEFINITIONS",
    "ReportDefinition",
    "allowed_definitions",
    "report_catalog_for_user",
]
