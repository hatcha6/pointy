import logging
from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

from django.conf import settings
from django.db import transaction
from django.db.models import Max
from django.urls import reverse
from django.utils import timezone

import base64

from apps.attachments.models import Attachment
from apps.attachments.services import (
    AttachmentStorageError,
    active_attachments_for,
    open_attachment,
    sign_attachment_content_token,
)
from apps.catalog.models import UnitOfMeasure
from apps.core.models import ShopSettings
from apps.discounts.models import AppliedDiscount
from apps.discounts.services import rounding_metadata_payload
from apps.sales.models import Order
from apps.sales.public_invoices import public_invoice_url_for_order
from .models import (
    PrepStation,
    PrintAgent,
    PrintAuditEvent,
    PrinterProfile,
    PrintJob,
    PrintJobEvent,
    PrintTemplate,
    PrintTemplateVersion,
)


logger = logging.getLogger(__name__)

DEFAULT_RECEIPT_TEMPLATE_SLUG = "receipt"
DEFAULT_KITCHEN_TEMPLATE_SLUG = "kitchen-ticket"
DEFAULT_PRINT_JOB_LEASE_SECONDS = 300


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


RECEIPT_LOGO_MAX_BYTES = 256 * 1024


def shop_logo_base64(shop_settings):
    """Inline the logo so the printing device can raster it on any thermal
    printer, even when it cannot reach the signed content URL."""
    attachment = (
        active_attachments_for(shop_settings, role=Attachment.Role.SHOP_LOGO)
        .filter(is_primary=True)
        .first()
    )
    if attachment is None or attachment.original_size > RECEIPT_LOGO_MAX_BYTES:
        return None
    try:
        with open_attachment(attachment) as handle:
            content = handle.read(RECEIPT_LOGO_MAX_BYTES + 1)
    except (OSError, AttachmentStorageError):
        return None
    if not content or len(content) > RECEIPT_LOGO_MAX_BYTES:
        return None
    return base64.b64encode(content).decode("ascii")


def build_receipt_payload(order):
    shop_settings = ShopSettings.load()
    order = (
        Order.objects.select_related("register_session")
        .prefetch_related(
            "lines__variant__product",
            "lines__variant__option_values__option",
            "lines__modifiers",
        )
        .get(pk=order.pk)
    )
    applied_discounts = order_applied_discounts(order)
    unit_labels = receipt_unit_labels()
    return {
        "shop": {
            "name": shop_settings.shop_name,
            "receipt_header": shop_settings.receipt_header,
            "receipt_footer": shop_settings.receipt_footer,
            "currency_symbol": shop_settings.currency_symbol,
            "logo": shop_logo_payload(shop_settings),
            "logo_bytes": shop_logo_base64(shop_settings),
        },
        "order": {
            "id": order.pk,
            "receipt_number": order.receipt_number,
            "public_invoice_url": public_invoice_url_for_order(
                order,
                shop_settings=shop_settings,
            ),
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
            "lines": [
                receipt_line_payload(line, unit_labels=unit_labels)
                for line in order.lines.all()
            ],
        },
    }


def receipt_unit_labels():
    """Map of unit code → short Arabic label for receipt rendering, resolved in
    one query so per-line payloads stay cheap."""
    return {
        unit.code: (unit.abbreviation or unit.name or unit.code)
        for unit in UnitOfMeasure.objects.all()
    }


def order_line_modifier_payloads(line):
    """The chosen modifiers for a line (snapshots), shared by receipt + chit."""
    return [
        {
            "group_name": modifier.group_name,
            "name": modifier.option_name,
            "quantity": modifier.quantity,
            "price_delta": money(modifier.unit_price_delta),
        }
        for modifier in line.modifiers.all()
    ]


def receipt_line_payload(line, *, unit_labels=None):
    variant = line.variant
    product = variant.product
    full_name = variant.full_name
    variant_name = variant.name.strip() or variant.display_name
    unit_code = line.unit or product.unit
    unit_label = (unit_labels or {}).get(unit_code, unit_code)
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
        "quantity": float(line.quantity),
        "unit": unit_code,
        "unit_label": unit_label,
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
        "modifiers": order_line_modifier_payloads(line),
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
            **rounding_metadata_payload(discount.metadata),
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


def print_job_lease_seconds():
    configured = getattr(
        settings,
        "POINTY_PRINT_JOB_LEASE_SECONDS",
        DEFAULT_PRINT_JOB_LEASE_SECONDS,
    )
    try:
        seconds = int(configured)
    except (TypeError, ValueError):
        return DEFAULT_PRINT_JOB_LEASE_SECONDS
    return max(30, seconds)


def print_job_lease_expires_at(now=None):
    claim_time = now or timezone.now()
    return claim_time + timedelta(seconds=print_job_lease_seconds())


def recover_stale_print_job_claims(*, user=None, now=None, limit=100):
    recovery_time = now or timezone.now()
    with transaction.atomic():
        stale_jobs = list(
            PrintJob.objects.select_for_update(skip_locked=True)
            .filter(
                status=PrintJob.Status.CLAIMED,
                lease_expires_at__lte=recovery_time,
            )
            .order_by("lease_expires_at", "id")[:limit]
        )
        for job in stale_jobs:
            _recover_locked_stale_claim(job, user=user, now=recovery_time)
    return stale_jobs


def claim_next_print_job(agent, *, user=None, printer_endpoint=None):
    now = timezone.now()
    with transaction.atomic():
        recover_stale_print_job_claims(user=user, now=now)
        job_queryset = PrintJob.objects.select_for_update(skip_locked=True).filter(
            status=PrintJob.Status.QUEUED,
        )
        if agent.printer_profile_id:
            job_queryset = job_queryset.filter(
                printer_profile_id__in=[agent.printer_profile_id, None],
            )
        job = job_queryset.order_by("-priority", "created_at", "id").first()
        agent.last_seen_at = now
        agent.save(update_fields=["last_seen_at", "updated_at"])
        if job is None:
            return None
        return _claim_locked_print_job(
            job,
            agent,
            user=user,
            printer_endpoint=printer_endpoint,
            now=now,
        )


def claim_print_job(job, agent, *, user=None, printer_endpoint=None):
    now = timezone.now()
    with transaction.atomic():
        locked_job = PrintJob.objects.select_for_update().get(pk=job.pk)
        _recover_locked_stale_claim(locked_job, user=user, now=now)
        if locked_job.status != PrintJob.Status.QUEUED:
            raise ValueError("Only queued jobs can be claimed.")

        claimed_job = _claim_locked_print_job(
            locked_job,
            agent,
            user=user,
            printer_endpoint=printer_endpoint,
            now=now,
        )

    claimed_job.refresh_from_db()
    return claimed_job


def _recover_locked_stale_claim(job, *, user=None, now=None):
    recovery_time = now or timezone.now()
    if job.status != PrintJob.Status.CLAIMED:
        return False
    if job.lease_expires_at is None or job.lease_expires_at > recovery_time:
        return False

    previous_agent_id = job.claimed_by_id
    previous_claimed_at = job.claimed_at
    previous_lease_expires_at = job.lease_expires_at
    job.status = PrintJob.Status.QUEUED
    job.claimed_by = None
    job.claimed_at = None
    job.lease_expires_at = None
    job.error_message = ""
    job.save(
        update_fields=[
            "status",
            "claimed_by",
            "claimed_at",
            "lease_expires_at",
            "error_message",
            "updated_at",
        ]
    )
    create_job_event(
        job,
        PrintJobEvent.Type.REQUEUED,
        user=user,
        message="Print job lease expired; job returned to queue.",
        metadata={
            "recovery_reason": "lease_expired",
            "previous_agent_id": previous_agent_id,
            "previous_claimed_at": (
                previous_claimed_at.isoformat() if previous_claimed_at else None
            ),
            "previous_lease_expires_at": (
                previous_lease_expires_at.isoformat()
                if previous_lease_expires_at
                else None
            ),
        },
    )
    return True


def _claim_locked_print_job(job, agent, *, user=None, printer_endpoint=None, now=None):
    claim_time = now or timezone.now()
    job.status = PrintJob.Status.CLAIMED
    job.claimed_by = agent
    job.claimed_at = claim_time
    job.lease_expires_at = print_job_lease_expires_at(claim_time)
    job.attempts += 1
    job.error_message = ""
    job.save(
        update_fields=[
            "status",
            "claimed_by",
            "claimed_at",
            "lease_expires_at",
            "attempts",
            "error_message",
            "updated_at",
        ]
    )
    create_job_event(
        job,
        PrintJobEvent.Type.CLAIMED,
        user=user,
        agent=agent,
        message="Print job claimed.",
        metadata={
            "printer_endpoint": printer_endpoint or {},
            "lease_expires_at": job.lease_expires_at.isoformat(),
        },
    )
    return job


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


def get_default_kitchen_template_version():
    template, _ = PrintTemplate.objects.get_or_create(
        slug=DEFAULT_KITCHEN_TEMPLATE_SLUG,
        defaults={
            "name": "Kitchen ticket",
            "template_type": PrintTemplate.Type.KITCHEN,
            "description": "Default kitchen ticket template.",
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
                "content": "{{ station.name }}\n{{ order.receipt_number }}",
                "schema": {"kind": "kitchen", "version": 1},
            },
        )
    template.current_version = version
    template.save(update_fields=["current_version", "updated_at"])
    return version


def kitchen_prepared_lines(order):
    """The made-to-order lines on an order, in order. A line is "prepared" when
    its product is flagged is_prepared (the same filter the kitchen board uses);
    retail/service lines never reach the kitchen."""
    lines = (
        order.lines.select_related("variant", "variant__product")
        .prefetch_related(
            "variant__product__categories",
            "variant__option_values__option",
            "modifiers",
        )
        .all()
    )
    return [line for line in lines if line.variant.product.is_prepared]


def resolve_prep_stations_for_order(order):
    """Group an order's prepared lines by the station that should print them.

    Returns (routed, prepared) where ``routed`` maps each PrepStation to its
    lines and ``prepared`` is every made-to-order line. A line routes to the
    first active station that owns one of its product's categories; anything
    unmatched falls to the single default station. If a line matches no station
    and there is no default, it is intentionally left out of ``routed`` (and
    therefore surfaced via ``prepared``) rather than silently dropped.
    """
    prepared = kitchen_prepared_lines(order)
    if not prepared:
        return {}, prepared

    stations = list(
        PrepStation.objects.filter(is_active=True).prefetch_related("categories")
    )
    station_by_category = {}
    default_station = None
    for station in stations:
        if station.is_default and default_station is None:
            default_station = station
        for category in station.categories.all():
            station_by_category.setdefault(category.id, station)

    routed = {}
    for line in prepared:
        category_ids = [
            category.id for category in line.variant.product.categories.all()
        ]
        target = next(
            (
                station_by_category[category_id]
                for category_id in category_ids
                if category_id in station_by_category
            ),
            None,
        )
        if target is None:
            target = default_station
        if target is None:
            continue
        routed.setdefault(target, []).append(line)
    return routed, prepared


def kitchen_line_payload(line):
    variant = line.variant
    return {
        "id": line.pk,
        "name": variant.full_name,
        "parent_product_name": variant.product.name,
        "quantity": float(line.quantity),
        "notes": line.notes,
        "option_values": [
            {
                "option_name": option_value.option.name,
                "value_name": option_value.name,
            }
            for option_value in variant.option_values.all()
        ],
        "modifiers": order_line_modifier_payloads(line),
    }


def build_kitchen_ticket_payload(order, station, lines):
    """A kitchen chit payload: what to cook, never what to charge. Carries no
    money — only the station, order reference, time, and the prepared lines with
    their options and free-text note. ``kind`` is the encoder discriminator."""
    shop_settings = ShopSettings.load()
    register = order.register_session
    return {
        "kind": "kitchen",
        "shop": {"name": shop_settings.shop_name},
        "station": {"id": station.pk, "name": station.name},
        "order": {
            "id": order.pk,
            "receipt_number": order.receipt_number,
            "document_title": "تذكرة المطبخ",
            "created_at": order.created_at.isoformat(),
            "customer_name": order.customer.full_name if order.customer_id else "",
            "register_session": (
                {
                    "session_number": order.register_session.session_number,
                    "owner_key": order.register_session.owner_key,
                }
                if register is not None
                else None
            ),
            "lines": [kitchen_line_payload(line) for line in lines],
        },
    }


def enqueue_kitchen_print_jobs(order_id):
    """Enqueue one kitchen ticket per routed station after payment (auto-print).

    Idempotent per (order, station) so re-checkout or retries never double-fire
    a chit. Each job is tagged with its station's printer_profile so the right
    device claims it (claim_next_print_job filters by profile). Like the receipt
    enqueue, this only fires when the shop has opted into auto kitchen tickets.
    """
    order = (
        Order.objects.select_related("register_session", "customer").get(pk=order_id)
    )
    if order.status != Order.Status.PAID:
        return []

    shop_settings = ShopSettings.load()
    if not shop_settings.auto_print_kitchen_tickets:
        return []

    routed, prepared = resolve_prep_stations_for_order(order)
    if prepared and not routed:
        logger.warning(
            "Order %s has %d made-to-order line(s) but no prep station routed "
            "them; mark a station as default to avoid lost kitchen tickets.",
            order.pk,
            len(prepared),
        )
    if not routed:
        return []

    template_version = get_default_kitchen_template_version()
    jobs = []
    for station, lines in routed.items():
        job, created = PrintJob.objects.get_or_create(
            idempotency_key=f"kitchen:{order.pk}:{station.pk}",
            defaults={
                "job_type": PrintJob.Type.KITCHEN,
                "order": order,
                "prep_station": station,
                "template_version": template_version,
                "printer_profile": station.printer_profile,
                "priority": station.priority,
                "payload": build_kitchen_ticket_payload(order, station, lines),
            },
        )
        if created:
            create_job_event(
                job,
                PrintJobEvent.Type.CREATED,
                message=f"Kitchen ticket queued for {station.name}.",
            )
        jobs.append(job)
    return jobs
