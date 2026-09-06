"""Catching up documents an older backend wrote during a live update.

A live update runs the new backend beside the old one: it migrates, passes
``/readyz/``, and only then does the front door flip
(``deploy/onprem/README.md``). For about a minute in the middle, **the old code
is still serving against the new schema** — and the old code knows nothing about
``doc_status``. The column's database default keeps its inserts working (that is
what ``db_default`` on the mixin is for), but a sale rung up in that minute
lands with the lifecycle of a draft and the progress of a finished sale.

Left alone that is a hazard rather than an untidiness: voiding such a sale would
take the *draft* path and reverse nothing, because a draft has nothing to
reverse. So the new backend puts them right.

It runs on ``post_migrate``, which fires again when the managed container is
rebuilt on the new image after the flip — by which time the window has closed
and every stale row is visible. Idempotent, indexed, and empty on a fresh
install.
"""

from django.db import connection
from django.db.models.signals import post_migrate
from django.dispatch import receiver

from .registry import all_types
from .statuses import DocumentStatus


def reconcile_lifecycles() -> int:
    """Give every finished document a finished lifecycle. Returns rows moved."""
    moved = 0

    # A type with no draft state cannot legitimately hold a draft: money either
    # moved or it did not, so any draft row is one an older backend inserted.
    for doc_type in all_types():
        if doc_type.has_draft_state or not has_lifecycle_column(doc_type.model):
            continue
        moved += doc_type.model.objects.filter(
            doc_status=DocumentStatus.DRAFT
        ).update(doc_status=DocumentStatus.SUBMITTED)

    # The rest have a real draft state, so the question is whether their own
    # progress field says the document finished. This is the same mapping the
    # backfill migrations used, applied to rows that arrived after them.
    moved += _reconcile_sales()
    moved += _reconcile_purchase_orders()
    moved += _reconcile_payroll_runs()
    moved += _reconcile_stock_counts()
    return moved


def _reconcile_sales() -> int:
    from apps.sales.models import Order

    if not has_lifecycle_column(Order):
        return 0
    drafts = Order.objects.filter(doc_status=DocumentStatus.DRAFT)
    return drafts.filter(status=Order.Status.PAID).update(
        doc_status=DocumentStatus.SUBMITTED
    ) + drafts.filter(status=Order.Status.VOID).update(
        doc_status=DocumentStatus.CANCELLED
    )


def _reconcile_purchase_orders() -> int:
    from apps.purchasing.models import PurchaseOrder

    if not has_lifecycle_column(PurchaseOrder):
        return 0
    drafts = PurchaseOrder.objects.filter(doc_status=DocumentStatus.DRAFT)
    return drafts.filter(
        status__in=(
            PurchaseOrder.Status.SUBMITTED,
            PurchaseOrder.Status.PARTIALLY_RECEIVED,
            PurchaseOrder.Status.RECEIVED,
        )
    ).update(doc_status=DocumentStatus.SUBMITTED) + drafts.filter(
        status=PurchaseOrder.Status.CANCELLED
    ).update(doc_status=DocumentStatus.CANCELLED)


def _reconcile_payroll_runs() -> int:
    from apps.employees.models import PayrollRun

    if not has_lifecycle_column(PayrollRun):
        return 0
    drafts = PayrollRun.objects.filter(doc_status=DocumentStatus.DRAFT)
    return drafts.filter(status=PayrollRun.Status.PAID).update(
        doc_status=DocumentStatus.SUBMITTED
    ) + drafts.filter(status=PayrollRun.Status.VOID).update(
        doc_status=DocumentStatus.CANCELLED
    )


def _reconcile_stock_counts() -> int:
    from apps.inventory.models import StockCount

    if not has_lifecycle_column(StockCount):
        return 0
    drafts = StockCount.objects.filter(doc_status=DocumentStatus.DRAFT)
    return drafts.filter(status=StockCount.Status.APPLIED).update(
        doc_status=DocumentStatus.SUBMITTED
    ) + drafts.filter(status=StockCount.Status.CANCELLED).update(
        doc_status=DocumentStatus.CANCELLED
    )


def has_lifecycle_column(model) -> bool:
    """Whether this model's table actually carries ``doc_status`` yet.

    Asked of the database, not the model. ``post_migrate`` fires for partial and
    backwards runs too — a test that rewinds one app to exercise a historical
    migration is a real example, and Django re-emits the signal after the flush
    it does around such a test — and there the live model has the column while
    the table does not. Nothing to repair in that state, so nothing is
    attempted.
    """
    table = model._meta.db_table
    with connection.cursor() as cursor:
        try:
            columns = connection.introspection.get_table_description(cursor, table)
        except Exception:
            return False
    return any(column.name == "doc_status" for column in columns)


@receiver(post_migrate)
def _reconcile_after_migrate(sender, **kwargs):
    # Once per ``migrate``, not once per installed app.
    if getattr(sender, "name", "") != "apps.documents":
        return
    reconcile_lifecycles()
