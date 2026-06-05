from decimal import Decimal
from uuid import uuid4

from django.db import transaction
from django.db.models import Max
from django.urls import reverse
from django.utils import timezone

from apps.attachments.models import Attachment
from apps.attachments.services import (
    active_attachments_for,
    sign_attachment_content_token,
)
from apps.core.models import ShopSettings
from apps.discounts.models import AppliedDiscount
from apps.sales.models import Order
from .models import (
    PrintAgent,
    PrintAuditEvent,
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


def shop_logo_payload(shop_settings):
    attachment = (
        active_attachments_for(shop_settings, role=Attachment.Role.SHOP_LOGO)
        .filter(is_primary=True)
        .first()
    )
    if attachment is None:
        return None

    content_path = reverse("attachment-content", kwargs={"pk": attachment.pk})
    token = sign_attachment_content_token(attachment)
    return {
        "id": attachment.pk,
        "original_filename": attachment.original_filename,
        "content_type": attachment.content_type,
        "content_url": f"{content_path}?token={token}",
        "is_primary": attachment.is_primary,
    }


def build_receipt_payload(order):
    shop_settings = ShopSettings.load()
    order = (
        Order.objects.select_related("register_session")
        .prefetch_related(
            "lines__variant__product",
            "lines__variant__option_values__option",
        )
        .get(pk=order.pk)
    )
    applied_discounts = order_applied_discounts(order)
    return {
        "shop": {
            "name": shop_settings.shop_name,
            "receipt_header": shop_settings.receipt_header,
            "receipt_footer": shop_settings.receipt_footer,
            "logo": shop_logo_payload(shop_settings),
        },
        "order": {
            "id": order.pk,
            "receipt_number": order.receipt_number,
            "status": order.status,
            "subtotal": money(order.subtotal),
            "discount_total": money(order.discount_total),
            "total": money(order.total),
            "applied_discounts": applied_discounts,
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
            "lines": [receipt_line_payload(line) for line in order.lines.all()],
        },
    }


def receipt_line_payload(line):
    variant = line.variant
    product = variant.product
    full_name = variant.full_name
    variant_name = variant.name.strip() or variant.display_name
    return {
        "id": line.pk,
        "product_id": product.pk,
        "variant_id": line.variant_id,
        "product_name": full_name,
        "parent_product_name": product.name,
        "variant_name": variant_name,
        "variant_display_name": variant.display_name,
        "sku": variant.sku,
        "barcode": variant.barcode,
        "name": full_name,
        "quantity": line.quantity,
        "unit_price": money(line.unit_price),
        "line_subtotal": money(line.line_subtotal),
        "discount_total": money(line.discount_total),
        "line_total": money(line.line_total),
        "option_values": [
            {
                "option_id": option_value.option_id,
                "option_name": option_value.option.name,
                "value_id": option_value.pk,
                "value_name": option_value.name,
                "value_code": option_value.code,
            }
            for option_value in variant.option_values.all()
        ],
    }


def order_applied_discounts(order):
    from django.contrib.contenttypes.models import ContentType

    document_content_type = ContentType.objects.get_for_model(
        order,
        for_concrete_model=False,
    )
    return [
        {
            "rule_name": discount.rule_name,
            "coupon_code": discount.coupon_code,
            "source": discount.source,
            "scope": discount.scope,
            "discount_amount": money(discount.discount_amount),
            "allocations": discount.allocations,
        }
        for discount in AppliedDiscount.objects.filter(
            document_content_type=document_content_type,
            document_object_id=order.pk,
        )
    ]


def create_job_event(job, event_type, *, user=None, agent=None, message="", metadata=None):
    event_metadata = metadata or {}
    event = PrintJobEvent.objects.create(
        job=job,
        event_type=event_type,
        user=user if user and user.is_authenticated else None,
        agent=agent,
        message=message,
        metadata=event_metadata,
    )
    create_print_audit_event_for_job_event(event)
    return event


def create_print_audit_event_for_job_event(event):
    if event.job.order_id is None:
        return None

    status_by_event_type = {
        PrintJobEvent.Type.PRINTED: PrintAuditEvent.Status.COMPLETED,
        PrintJobEvent.Type.FAILED: PrintAuditEvent.Status.FAILED,
        PrintJobEvent.Type.CANCELED: PrintAuditEvent.Status.CANCELED,
    }
    audit_status = status_by_event_type.get(event.event_type)
    if audit_status is None:
        return None

    metadata = {
        **(event.metadata or {}),
        "print_job_event_id": event.pk,
    }
    return create_print_audit_event(
        document_type=PrintAuditEvent.DocumentType.SALE_ORDER,
        action=PrintAuditEvent.Action.PRINT,
        status=audit_status,
        sale_order=event.job.order,
        user=event.user,
        agent=event.agent,
        printer_endpoint=(event.metadata or {}).get("printer_endpoint", {}),
        print_job=event.job,
        message=event.message,
        metadata=metadata,
    )


def create_print_audit_event(
    *,
    document_type,
    action,
    status=PrintAuditEvent.Status.REQUESTED,
    sale_order=None,
    purchase_order=None,
    user=None,
    agent=None,
    agent_identifier="",
    printer_endpoint=None,
    device_name="",
    printer_name="",
    print_job=None,
    message="",
    metadata=None,
):
    endpoint = printer_endpoint if isinstance(printer_endpoint, dict) else {}
    event_metadata = metadata or {}
    agent_identifier = agent_identifier or (agent.identifier if agent else "")
    return PrintAuditEvent.objects.create(
        document_type=document_type,
        action=action,
        status=status,
        sale_order=sale_order,
        purchase_order=purchase_order,
        document_number=print_audit_document_number(
            document_type,
            sale_order=sale_order,
            purchase_order=purchase_order,
        ),
        print_job=print_job,
        user=user if user and user.is_authenticated else None,
        agent=agent,
        agent_identifier=agent_identifier,
        device_name=device_name or event_metadata.get("device_name", "") or agent_identifier,
        printer_name=printer_name or printer_name_from_endpoint(endpoint),
        printer_endpoint=endpoint,
        message=message,
        metadata=event_metadata,
    )


def report_print_audit_event(audit_event, *, status, message="", metadata=None):
    audit_event.status = status
    if message:
        audit_event.message = message
    if metadata:
        audit_event.metadata = {
            **(audit_event.metadata or {}),
            **metadata,
        }
    audit_event.save(update_fields=["status", "message", "metadata", "updated_at"])
    return audit_event


def print_audit_document_number(document_type, *, sale_order=None, purchase_order=None):
    if document_type == PrintAuditEvent.DocumentType.SALE_ORDER and sale_order is not None:
        return sale_order.receipt_number or str(sale_order.pk)
    if (
        document_type == PrintAuditEvent.DocumentType.PURCHASE_ORDER
        and purchase_order is not None
    ):
        return purchase_order.order_number or str(purchase_order.pk)
    return ""


def printer_name_from_endpoint(endpoint):
    if not isinstance(endpoint, dict):
        return ""
    for key in ("name", "printer_name", "address", "path"):
        value = endpoint.get(key)
        if value:
            return str(value)
    kind = endpoint.get("kind") or endpoint.get("transport")
    return "" if kind is None else str(kind)


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
