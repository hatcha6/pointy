"""The chat tool that turns a photographed invoice into a reviewable draft PO.

This replaces the old arrangement where the chat model *was* the pipeline: it
extracted the lines itself, matched them one call at a time, and asked a question
per unmatched line, all inside a bounded round budget with the image visible only
on the first turn. Here the model makes one call, the server does the work, and
the user gets a single card to check.

What the model gets back is deliberately a summary, not the plan: it needs enough
to write a sentence about what happened, and nothing more. The plan itself rides
the generated review card, and the user applies it from there.
"""

from __future__ import annotations

import base64
import logging

from django.core.files.uploadedfile import SimpleUploadedFile

from apps.attachments.models import Attachment
from apps.attachments.services import (
    AttachmentStorageError,
    open_attachment,
    store_uploaded_attachment,
)
from apps.core.relay import RelayControlError
from apps.invoice_intake.models import InvoiceIntake
from apps.invoice_intake.services import run_pipeline

from .invoice_extraction import extract_invoice
from .ui_invoice_review import build_invoice_review_surface

logger = logging.getLogger(__name__)

# Bounds what one chat turn may read. A supplier invoice runs to a page or two;
# anything past this is a scanning mistake, not an invoice.
MAX_PAGES = 8


# A page larger than this is a photo that should have been downscaled before
# upload; sending it would blow the relay body cap for no extra readability.
MAX_PAGE_BYTES = 6 * 1024 * 1024


def _page_attachments(intake):
    """The stored pages as relay attachment payloads (base64 data URIs).

    Pages live on an attachment storage volume rather than inline, so each one
    is read and encoded here. A page that cannot be read is skipped rather than
    failing the whole invoice: the rest of it is still worth reading.
    """
    payloads = []
    for attachment in intake.pages.all()[:MAX_PAGES]:
        mime = attachment.content_type or "application/octet-stream"
        try:
            with open_attachment(attachment) as handle:
                raw = handle.read(MAX_PAGE_BYTES + 1)
        except (AttachmentStorageError, OSError):
            logger.warning(
                "invoice intake: page %s could not be read", attachment.pk, exc_info=True
            )
            continue
        if not raw or len(raw) > MAX_PAGE_BYTES:
            logger.warning("invoice intake: page %s skipped (size)", attachment.pk)
            continue
        encoded = base64.b64encode(raw).decode("ascii")
        payloads.append(
            {
                "kind": "image" if mime.startswith("image/") else "file",
                "data_uri": f"data:{mime};base64,{encoded}",
                "name": attachment.original_filename or "invoice",
                "mime": mime,
            }
        )
    return payloads


def _summary(intake):
    """A compact, honest account of what the pipeline produced."""
    counts = intake.counts()
    plan = intake.plan or {}
    supplier = plan.get("supplier") or {}
    totals = (plan.get("totals_check") or {})
    return {
        "ok": True,
        "intake_id": intake.pk,
        "status": intake.status,
        "supplier": {
            "matched": bool(supplier.get("id")),
            "name": (supplier.get("create") or {}).get("name")
            or supplier.get("name")
            or "",
        },
        "lines": counts,
        "totals_ok": bool(totals.get("ok", True)),
        "needs_review": intake.needs_review,
        # The card is already on the user's screen; the model must not restate
        # the whole invoice back to them.
        "note": (
            "عُرضت بطاقة المراجعة للمستخدم. اذكر باختصار ما قرأته وما يحتاج "
            "انتباهه، ولا تُعد سرد كل السطور."
        ),
    }


_IMAGE_MIMES = ("image/",)
_DOC_MIMES = ("application/pdf",)


def _decode_data_uri(data_uri):
    """Split a ``data:<mime>;base64,<payload>`` string into (mime, bytes)."""
    if not isinstance(data_uri, str) or not data_uri.startswith("data:"):
        return None, None
    header, _, payload = data_uri.partition(",")
    if not payload:
        return None, None
    mime = header[5:].split(";", 1)[0].strip() or "application/octet-stream"
    if ";base64" not in header:
        return None, None
    try:
        raw = base64.b64decode(payload, validate=False)
    except (ValueError, TypeError):
        return None, None
    return mime, raw


def _store_pages(intake, attachments, *, user):
    """Persist this turn's invoice pages against the intake.

    Chat attachments are otherwise never written to disk — only their metadata
    is kept. An invoice is different: the paper document is the authoritative
    record in this market, so the photo has to travel with the purchase order it
    produced. On apply, these same rows are re-pointed at that order.
    """
    stored = []
    for index, attachment in enumerate(attachments[:MAX_PAGES], start=1):
        mime, raw = _decode_data_uri((attachment or {}).get("data_uri"))
        if not raw or len(raw) > MAX_PAGE_BYTES:
            continue
        if not (mime.startswith(_IMAGE_MIMES) or mime in _DOC_MIMES):
            continue
        name = (attachment.get("name") or f"invoice-{index}").strip()[:120]
        try:
            stored.append(
                store_uploaded_attachment(
                    uploaded_file=SimpleUploadedFile(name, raw, content_type=mime),
                    owner=intake,
                    role=Attachment.Role.GENERAL,
                    created_by=user,
                    metadata={"source": "invoice_intake"},
                )
            )
        except Exception:  # noqa: BLE001 - a bad page must not lose the others
            logger.warning("invoice intake: could not store page %s", index, exc_info=True)
    return stored


def start_invoice_intake(*, user, installation, attachments=None, source="chat"):
    """Read the invoice pages attached to this turn into a purchase-order plan.

    Returns ``(result, surface)``: a compact summary for the model, and the
    review card for the user (or ``None`` when the read failed).

    The model passes no ids: the server already knows what the user attached
    this turn, and asking a model to thread identifiers through is a reliable
    way to get the wrong invoice read.
    """
    pages = [a for a in (attachments or []) if isinstance(a, dict)]
    if not pages:
        return {
            "ok": False,
            "error": "no_pages",
            "message": (
                "لا توجد صورة فاتورة في هذه الرسالة. اطلب من المستخدم إرسال صورة "
                "الفاتورة ثم أعد المحاولة."
            ),
        }, None

    intake = InvoiceIntake.objects.create(
        created_by=user,
        source=source,
        status=InvoiceIntake.Status.EXTRACTING,
    )
    stored = _store_pages(intake, pages, user=user)
    if not stored:
        intake.status = InvoiceIntake.Status.FAILED
        intake.error = "no readable invoice pages"
        intake.save(update_fields=["status", "error", "updated_at"])
        return {
            "ok": False,
            "error": "unreadable_pages",
            "message": "تعذّر حفظ صور الفاتورة. اطلب صورة أوضح بصيغة JPG أو PDF.",
        }, None
    intake.pages.set(stored)

    try:
        extraction, _problems = extract_invoice(
            installation=installation,
            attachments=_page_attachments(intake),
        )
    except (RelayControlError, ValueError) as error:
        logger.warning("invoice intake: extraction failed", exc_info=True)
        intake.status = InvoiceIntake.Status.FAILED
        intake.error = str(error)
        intake.save(update_fields=["status", "error", "updated_at"])
        return {
            "ok": False,
            "error": "extraction_failed",
            "intake_id": intake.pk,
            "message": (
                "تعذّرت قراءة الفاتورة من الصورة. اطلب صورة أوضح للفاتورة كاملة "
                "وبإضاءة أفضل."
            ),
        }, None

    run_pipeline(intake, extraction, user=user)
    intake.refresh_from_db()

    if intake.status == InvoiceIntake.Status.FAILED:
        return {
            "ok": False,
            "error": "pipeline_failed",
            "intake_id": intake.pk,
            "message": intake.error or "تعذّرت معالجة الفاتورة.",
        }, None

    return _summary(intake), build_invoice_review_surface(intake)


def start_invoice_intake_tool_definition():
    return {
        "type": "function",
        "function": {
            "name": "start_invoice_intake",
            "description": (
                "اقرأ فاتورة مورّد مصوّرة وحوّلها إلى أمر شراء جاهز للمراجعة. "
                "استدعِها مباشرة عندما يرسل المستخدم صورة فاتورة أو يطلب إدخال "
                "فاتورة. لا تستخرج السطور بنفسك ولا تطابق الأصناف يدويًا — هذه "
                "الأداة تقرأ وتطابق وتسعّر وتجهّز بطاقة مراجعة واحدة. مرّر معرّفات "
                "صور الفاتورة المرفقة في هذه الرسالة تُقرأ تلقائيًا."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            },
        },
    }
