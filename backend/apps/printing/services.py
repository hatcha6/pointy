from decimal import Decimal
from uuid import uuid4

from django.db import transaction
from django.db.models import Max
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.sales.models import Order
from .models import (
    PrintAgent,
    PrinterProfile,
    PrintJob,
    PrintJobEvent,
    PrintTemplate,
    PrintTemplateVersion,
)


DEFAULT_RECEIPT_TEMPLATE_SLUG = "receipt"


def next_template_version_number(template):
    highest = template.versions.aggregate(highest=Max("version_number"))["highest"]
    return (highest or 0) + 1


def publish_template_version(version):
    now = timezone.now()
    with transaction.atomic():
        locked_version = PrintTemplateVersion.objects.select_for_update().get(pk=version.pk)
        if locked_version.status != PrintTemplateVersion.Status.PUBLISHED:
            locked_version.status = PrintTemplateVersion.Status.PUBLISHED
            locked_version.published_at = now
            locked_version.save(update_fields=["status", "published_at", "updated_at"])
        PrintTemplate.objects.filter(pk=locked_version.template_id).update(
            current_version=locked_version,
            updated_at=now,
        )
    locked_version.refresh_from_db()
    return locked_version


def get_default_receipt_template_version():
    template, _ = PrintTemplate.objects.get_or_create(
        slug=DEFAULT_RECEIPT_TEMPLATE_SLUG,
        defaults={
            "name": "Receipt",
            "template_type": PrintTemplate.Type.RECEIPT,
            "description": "Default receipt template.",
        },
    )
    if template.current_version_id:
        return template.current_version

    version = (
        template.versions.filter(status=PrintTemplateVersion.Status.PUBLISHED)
        .order_by("-version_number")
        .first()
    )
    if version is None:
        version, _ = PrintTemplateVersion.objects.get_or_create(
            template=template,
            version_number=1,
            defaults={
                "status": PrintTemplateVersion.Status.PUBLISHED,
                "published_at": timezone.now(),
                "content": "{{ shop.name }}\n{{ order.receipt_number }}",
                "schema": {"kind": "receipt", "version": 1},
            },
        )
    template.current_version = version
    template.save(update_fields=["current_version", "updated_at"])
    return version


def get_default_printer_profile():
    return (
        PrinterProfile.objects.filter(is_active=True, is_default=True).first()
        or PrinterProfile.objects.filter(is_active=True).order_by("name").first()
    )


def money(value):
    if isinstance(value, Decimal):
        return str(value.quantize(Decimal("0.01")))
    return str(value)


def build_receipt_payload(order):
    shop_settings = ShopSettings.load()
    order = (
        Order.objects.select_related("register_session")
        .prefetch_related("lines__product")
        .get(pk=order.pk)
    )
    return {
        "shop": {
            "name": shop_settings.shop_name,
            "receipt_header": shop_settings.receipt_header,
            "receipt_footer": shop_settings.receipt_footer,
        },
        "order": {
            "id": order.pk,
            "receipt_number": order.receipt_number,
            "status": order.status,
            "subtotal": money(order.subtotal),
            "total": money(order.total),
            "created_at": order.created_at.isoformat(),
            "register_session": (
                {
                    "id": order.register_session_id,
                    "session_number": order.register_session.session_number,
                    "owner_key": order.register_session.owner_key,
                }
                if order.register_session_id
                else None
            ),
            "lines": [
                {
                    "product_id": line.product_id,
                    "sku": line.product.sku,
                    "name": line.product.name,
                    "quantity": line.quantity,
                    "unit_price": money(line.unit_price),
                    "line_total": money(line.line_total),
                }
                for line in order.lines.all()
            ],
        },
    }


def create_job_event(job, event_type, *, user=None, agent=None, message="", metadata=None):
    return PrintJobEvent.objects.create(
        job=job,
        event_type=event_type,
        user=user if user and user.is_authenticated else None,
        agent=agent,
        message=message,
        metadata=metadata or {},
    )


def get_or_create_print_agent(identifier):
    agent, _ = PrintAgent.objects.get_or_create(
        identifier=identifier,
        defaults={"name": identifier},
    )
    return agent


def claim_print_job(job, agent, *, user=None, printer_endpoint=None):
    now = timezone.now()
    with transaction.atomic():
        locked_job = PrintJob.objects.select_for_update().get(pk=job.pk)
        if locked_job.status != PrintJob.Status.QUEUED:
            raise ValueError("Only queued jobs can be claimed.")

        locked_job.status = PrintJob.Status.CLAIMED
        locked_job.claimed_by = agent
        locked_job.claimed_at = now
        locked_job.attempts += 1
        locked_job.error_message = ""
        locked_job.save(
            update_fields=[
                "status",
                "claimed_by",
                "claimed_at",
                "attempts",
                "error_message",
                "updated_at",
            ]
        )
        agent.last_seen_at = now
        agent.save(update_fields=["last_seen_at", "updated_at"])
        create_job_event(
            locked_job,
            PrintJobEvent.Type.CLAIMED,
            user=user,
            agent=agent,
            message="Print job claimed.",
            metadata={"printer_endpoint": printer_endpoint or {}},
        )

    locked_job.refresh_from_db()
    return locked_job


def enqueue_receipt_print_job(order_id):
    order = Order.objects.get(pk=order_id)
    if order.status != Order.Status.PAID:
        return None

    shop_settings = ShopSettings.load()
    if not shop_settings.auto_print_receipts:
        return None

    template_version = get_default_receipt_template_version()
    payload = build_receipt_payload(order)
    job, created = PrintJob.objects.get_or_create(
        idempotency_key=f"receipt:{order.pk}",
        defaults={
            "job_type": PrintJob.Type.RECEIPT,
            "order": order,
            "template_version": template_version,
            "printer_profile": get_default_printer_profile(),
            "payload": payload,
        },
    )
    if created:
        create_job_event(
            job,
            PrintJobEvent.Type.CREATED,
            message="Receipt print job queued after payment.",
        )
    return job


def enqueue_manual_receipt_reprint(order, *, user=None):
    template_version = get_default_receipt_template_version()
    job = PrintJob.objects.create(
        idempotency_key=f"receipt-reprint:{order.pk}:{uuid4()}",
        job_type=PrintJob.Type.RECEIPT,
        order=order,
        template_version=template_version,
        printer_profile=get_default_printer_profile(),
        payload=build_receipt_payload(order),
    )
    create_job_event(
        job,
        PrintJobEvent.Type.CREATED,
        user=user,
        message="Receipt reprint queued.",
    )
    return job
