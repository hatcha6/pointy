"""Mark put back the job parts a return already put on the shelf.

A return on a job's invoice used to restock the part like any sale line, while
the job went on calling the part consumed. From now on a return gives the money
back and the part stays with the job (``apps.operations.invoice_returns``), and
a part refunded that way may then be put back on the shelf through the job. So
a part an older return had already restocked would be stocked twice the day
someone did that.

The ledger already says those parts came back, so the job is brought into line
with it, with no movement of its own. Only a part whose invoice line came back
in full: when only some of a line came back, nobody can say which pieces did.
Voided invoices are left to the operations catch-up that releases their jobs.

In the sales app rather than operations because it is the returns that it
settles, and so that it needs no operations migration beyond the last one
already shipped.
"""

from collections import defaultdict

from django.db import migrations
from django.db.models import Sum
from django.utils import timezone


def put_back_parts_already_returned(apps, schema_editor):
    Job = apps.get_model("operations", "Job")
    JobMaterial = apps.get_model("operations", "JobMaterial")
    OrderLine = apps.get_model("sales", "OrderLine")
    OrderAdjustmentLine = apps.get_model("sales", "OrderAdjustmentLine")

    now = timezone.now()
    jobs = (
        Job.objects.filter(order__isnull=False)
        .exclude(order__status="void")
        .exclude(workflow_template__job_type="kitchen")
        .select_related("order")
    )
    for job in jobs:
        order = job.order
        returned = dict(
            OrderAdjustmentLine.objects.filter(order_line__order=order)
            .values("order_line")
            .annotate(quantity=Sum("quantity"))
            .values_list("order_line", "quantity")
        )
        if not returned:
            continue
        # The pairing ``invoice_returns.billed_parts`` makes: one line per part
        # the job had consumed, in the order it used them.
        candidates = defaultdict(list)
        for material in JobMaterial.objects.filter(
            job=job, consumed_at__isnull=False
        ).order_by("created_at", "id"):
            if material.reversed_at is not None and material.reversed_at < order.created_at:
                continue
            candidates[(material.variant_id, material.quantity)].append(material)
        for line in (
            OrderLine.objects.filter(order=order)
            .select_related("variant__product")
            .order_by("pk")
        ):
            product = line.variant.product
            if product.is_service:
                continue
            queue = candidates.get((line.variant_id, line.quantity))
            if not queue:
                continue
            material = queue.pop(0)
            if (
                material.reversed_at is not None
                or product.tracking_mode != "quantity"
                or returned.get(line.pk, 0) < line.quantity
            ):
                continue
            material.reversed_at = now
            material.save(update_fields=["reversed_at", "updated_at"])


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0037_order_extra_discount_amount"),
        ("operations", "0010_job_decline_and_hand_back"),
        ("catalog", "0033_productcategory_system_key"),
    ]

    operations = [
        migrations.RunPython(
            put_back_parts_already_returned, migrations.RunPython.noop
        ),
    ]
