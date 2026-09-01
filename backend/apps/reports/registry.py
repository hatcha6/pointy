"""Which function builds which report, and the context every builder is handed.

The context exists so a builder states *what* it wants — the period's orders,
this section's row cap, the headline block — and never re-derives *how*. Row
caps, comparison figures, the as-of date and the summary-only mode are decided
once here; a builder that made those decisions itself would make them slightly
differently from the next one, which is how nine reports came to disagree about
what "this month" meant.
"""

from dataclasses import dataclass, field, replace

from django.utils import timezone

from .definitions import REPORT_DEFINITIONS
from .periods import ReportPeriod
from .sections import metric_section

# Base row caps per section, before the granularity multiplier. A section not
# named here gets ``DEFAULT_ROW_LIMIT``.
DEFAULT_ROW_LIMIT = 120
SHORT_ROW_LIMIT = 24
CHOICE_ROW_LIMIT = 32

SECTION_ROW_LIMITS = {
    "top_products": SHORT_ROW_LIMIT,
    "recent_orders": SHORT_ROW_LIMIT,
    "margin_losses": SHORT_ROW_LIMIT,
    "category_margin": CHOICE_ROW_LIMIT,
    "discount_rules": CHOICE_ROW_LIMIT,
    "giveaway_by_staff": CHOICE_ROW_LIMIT,
    "payment_methods": CHOICE_ROW_LIMIT,
    "movement_mix": CHOICE_ROW_LIMIT,
    "expense_categories": CHOICE_ROW_LIMIT,
}


class ReportValidationError(ValueError):
    """A report cannot be built from the parameters it was given."""


@dataclass
class ReportContext:
    """Everything a builder needs, and nothing it should decide for itself."""

    user: object
    period: ReportPeriod
    definition: object
    params: dict = field(default_factory=dict)
    #: The comparison window's headline figures, when one was asked for.
    previous_summary: dict | None = None
    #: Build the headline only — used for the comparison pass, whose detail
    #: sections are thrown away. Detail sections cost nothing in this mode.
    summary_only: bool = False
    #: Overrides the granularity multiplier on every section cap. Set by the
    #: CSV export, which is not stored and can afford rows a stored payload
    #: cannot.
    row_scale: int | None = None
    today: object = None

    # -- period ------------------------------------------------------------

    def as_of_date(self):
        """The day a point-in-time figure is stated at: the period's last day."""
        return self.period.end_date

    def is_historical(self):
        """Whether the period ends before today, so "now" is not the answer."""
        return self.as_of_date() < (self.today or timezone.localdate())

    def at(self, when):
        """A context positioned at a single past day — for opening balances."""
        return replace(
            self,
            period=ReportPeriod(start_date=when, end_date=when),
            previous_summary=None,
            summary_only=True,
        )

    def with_period(self, period):
        return replace(self, period=period, previous_summary=None)

    def for_report(self, key):
        """The same window and user, reading as a different report."""
        return replace(
            self,
            definition=REPORT_DEFINITIONS[key],
            previous_summary=None,
            summary_only=False,
        )

    # -- sections ----------------------------------------------------------

    def row_limit(self, section_key):
        if self.summary_only:
            return 0
        base = SECTION_ROW_LIMITS.get(section_key, DEFAULT_ROW_LIMIT)
        if self.row_scale is not None:
            return base * self.row_scale
        return self.period.row_limit(base)

    def metrics(self, figures):
        """The headline block, with the comparison column when one was asked
        for. Ordered by the report's own ``headline`` list first, so the figures
        an owner should read first are the ones at the top — the PDF used to
        take whichever eight came out of the dictionary first."""
        ordered = [
            (name, figures[name])
            for name in self.definition.headline
            if name in figures
        ]
        ordered.extend(
            (name, value)
            for name, value in figures.items()
            if name not in self.definition.headline
        )
        return metric_section(ordered, previous=self.previous_summary)

    # -- parameters --------------------------------------------------------

    def param(self, name, default=None):
        return self.params.get(name, default)

    def validation_error(self, message):
        return ReportValidationError(message)


BUILDERS = {}


def _load():
    if BUILDERS:
        return BUILDERS
    from .builders import cash, inventory, people, profit, purchasing, receivables, sales
    from .models import ReportRun

    Type = ReportRun.ReportType
    BUILDERS.update(
        {
            Type.SALES_SUMMARY: sales.sales_summary,
            Type.PAYMENT_METHODS: cash.payment_methods,
            Type.REGISTER_CLOSURE: cash.register_closure,
            Type.CASH_POSITION: cash.cash_position,
            Type.INVENTORY_STATUS: inventory.inventory_status,
            Type.STOCK_MOVEMENTS: inventory.stock_movements,
            Type.REORDER_ITEMS: inventory.reorder_items,
            Type.PURCHASING_SUMMARY: purchasing.purchasing_summary,
            Type.PAYABLES_AGING: purchasing.payables_aging,
            Type.SUPPLIER_STATEMENT: purchasing.supplier_statement,
            Type.RECEIVABLES_AGING: receivables.receivables_aging,
            Type.CUSTOMER_STATEMENT: receivables.customer_statement,
            Type.PAYROLL_SUMMARY: people.payroll_summary,
            Type.PROFIT_COSTS: profit.profit_costs,
            Type.EXPENSE_BREAKDOWN: profit.expense_breakdown,
            Type.MONTH_END_PACK: profit.month_end_pack,
            Type.PRODUCT_MARGIN: sales.product_margin,
            Type.DISCOUNT_AUDIT: sales.discount_audit,
            Type.SALES_BY_STAFF: sales.sales_by_staff,
        }
    )
    return BUILDERS


def definition(key):
    return REPORT_DEFINITIONS.get(key)


def build(key, context):
    builder = _load().get(key)
    if builder is None:
        raise ReportValidationError("Unknown report type.")
    payload = builder(context)
    payload["notes"] = [entry for entry in payload.get("notes", []) if entry]
    return payload


__all__ = [
    "BUILDERS",
    "DEFAULT_ROW_LIMIT",
    "ReportContext",
    "ReportValidationError",
    "SECTION_ROW_LIMITS",
    "build",
    "definition",
]
