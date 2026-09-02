"""Run the intake pipeline, and apply a reviewed plan in one transaction.

Two entry points:

``run_pipeline``
    extraction → arithmetic checks → reconciliation → plan, stored on the
    intake. Pure reads.

``apply_intake``
    the only writer. Everything it creates goes through the *real* serializers
    and viewsets as the requesting user — the supplier through
    ``SupplierViewSet``, products through ``ProductViewSet`` (so SKU generation
    and the duplicate-barcode ``conflicts`` 400 apply), the order through
    ``PurchaseOrderSerializer`` → ``save_purchase_order_with_lines`` (so the
    cost guard, the valuation ledger, the audit event and the catalog version
    bump are the real ones). Nothing here re-implements a write path, which is
    the whole point: an invoice typed by a person and an invoice read by a
    camera must land in the same state.

It is one ``transaction.atomic()`` keyed on the intake: a conflict on line 30
leaves no orphan products from lines 1–29, and re-applying an applied intake
returns the purchase order it already made rather than making a second one.
"""

import logging
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import APIException

from .models import InvoiceIntake

logger = logging.getLogger(__name__)


class IntakeApplyError(APIException):
    """A sub-request refused. Carries that refusal's status (a 403 from the
    product viewset must reach the client as a 403, not as a generic 400) and
    names the stage and line it happened on, so the review card can highlight
    the offending row instead of showing "something went wrong"."""

    status_code = 400
    default_detail = "Invoice intake could not be applied."

    def __init__(self, stage, response, *, line_index=None):
        status_code = getattr(response, "status_code", 400)
        self.status_code = status_code if status_code in (400, 403, 404, 409) else 400
        detail = {"stage": stage, "error": getattr(response, "data", str(response))}
        if line_index is not None:
            detail["line_index"] = line_index
        super().__init__(detail)

    @classmethod
    def bad_request(cls, stage, detail, *, line_index=None):
        """A refusal this module decided on its own (rather than one a viewset
        handed back)."""
        return cls(
            stage,
            _Refusal(400, detail if isinstance(detail, dict) else {"detail": detail}),
            line_index=line_index,
        )


class _Refusal:
    """The two attributes :class:`IntakeApplyError` reads off a DRF response."""

    __slots__ = ("status_code", "data")

    def __init__(self, status_code, data):
        self.status_code = status_code
        self.data = data


def _decimal(value):
    from .schemas import to_decimal

    return to_decimal(value)


# ── Pipeline ─────────────────────────────────────────────────────────────────


def run_pipeline(intake, raw_extraction, *, user, supplier=None):
    """Normalise ``raw_extraction``, check its arithmetic, reconcile it and
    store the resulting plan on ``intake``. Never raises: a pipeline that fails
    marks the intake ``failed`` with the reason, because a half-read invoice
    still has to be visible enough for the user to retake the photo."""
    from .plan import build_plan
    from .reconcile import reconcile_lines
    from .schemas import normalise_extraction

    extraction = normalise_extraction(raw_extraction)
    intake.extraction = extraction
    intake.status = InvoiceIntake.Status.RECONCILING
    intake.save(update_fields=["extraction", "status", "updated_at"])

    try:
        reconciliation = reconcile_lines(extraction, user, supplier=supplier)
        plan = build_plan(extraction, reconciliation, user)
    except Exception as error:  # pragma: no cover - defensive
        logger.exception("Invoice intake pipeline failed")
        intake.status = InvoiceIntake.Status.FAILED
        intake.error = str(error)
        intake.save(update_fields=["status", "error", "updated_at"])
        return intake

    checks = plan["totals_check"]
    supplier_id = (plan.get("supplier") or {}).get("id")
    intake.plan = plan
    intake.supplier_id = supplier_id
    intake.confidence_summary = {
        "lines": plan["summary"],
        "totals_ok": checks["ok"],
        "flagged_line_indexes": checks["line_indexes"],
        "warnings": extraction.get("warnings", []),
    }
    intake.status = InvoiceIntake.Status.PLANNED
    intake.error = ""
    intake.save(
        update_fields=[
            "plan",
            "supplier",
            "confidence_summary",
            "status",
            "error",
            "updated_at",
        ]
    )
    return intake


# ── Apply ────────────────────────────────────────────────────────────────────


def _dispatch(view_class, *, action, method, user, data=None, kwargs=None, stage, line_index=None):
    """Run one write through its real viewset, or raise with what it refused.

    A viewset returns a 4xx response rather than raising, so the check has to be
    explicit — silently ignoring it is how half-applied invoices happen.
    """
    from apps.ai.tools import _run_write_viewset

    response = _run_write_viewset(
        view_class, action=action, method=method, user=user, data=data, kwargs=kwargs
    )
    if not (200 <= response.status_code < 300):
        raise IntakeApplyError(stage, response, line_index=line_index)
    return response.data


def _resolve_supplier(plan, *, user):
    from apps.purchasing.models import Supplier
    from apps.purchasing.views import SupplierViewSet

    supplier_plan = plan.get("supplier") or {}
    supplier_id = supplier_plan.get("id")
    if supplier_id:
        supplier = Supplier.objects.filter(pk=supplier_id).first()
        if supplier is None:
            raise IntakeApplyError.bad_request("supplier", {"supplier": "Unknown supplier."})
        return supplier
    create = supplier_plan.get("create") or {}
    payload = {
        "name": (create.get("name") or "").strip(),
        "phone": create.get("phone") or "",
        "address": create.get("address") or "",
        "notes": create.get("notes") or "",
    }
    if not payload["name"]:
        raise IntakeApplyError.bad_request(
            "supplier", {"supplier": "Supplier name is required."}
        )
    data = _dispatch(
        SupplierViewSet,
        action="create",
        method="post",
        user=user,
        data=payload,
        stage="supplier",
    )
    return Supplier.objects.get(pk=data["id"])


def _create_products(plan, *, user):
    """Create every new product the plan proposes, returning
    ``create_ref -> {"product_id", "variant_id"}``.

    Through ``ProductViewSet`` so a duplicate SKU/barcode comes back as the
    structured ``conflicts`` 400 the product dialog already knows how to show —
    and, because we are inside the apply transaction, aborts the whole invoice
    rather than leaving the first half of it behind.
    """
    from apps.catalog.views import ProductViewSet

    created = {}
    for entry in plan.get("creates") or []:
        ref = entry.get("create_ref")
        product = entry.get("product") or {}
        name = (product.get("name") or "").strip()
        if not ref or not name:
            continue
        unit_price = product.get("unit_price")
        payload = {
            "name": name,
            "unit": product.get("unit") or "piece",
            "tracks_expiry": bool(product.get("tracks_expiry")),
            "default_variant": {
                "unit_price": unit_price if unit_price is not None else "0.00",
                "barcode": product.get("barcode") or "",
            },
        }
        if product.get("categories"):
            payload["categories"] = product["categories"]
        unit = entry.get("unit") or {}
        if unit.get("unit") and unit.get("factor_to_base"):
            payload["units"] = [
                {
                    "unit": unit["unit"],
                    "factor_to_base": unit["factor_to_base"],
                    "is_purchasable": True,
                }
            ]
        data = _dispatch(
            ProductViewSet,
            action="create",
            method="post",
            user=user,
            data=payload,
            stage="product",
            line_index=entry.get("line_index"),
        )
        default_variant = data.get("default_variant") or {}
        variant_id = default_variant.get("id")
        if variant_id is None:
            variants = data.get("variants") or []
            variant_id = variants[0].get("id") if variants else None
        created[ref] = {"product_id": data.get("id"), "variant_id": variant_id}
    return created


def _ensure_units(plan, created, *, user):
    """Add a proposed purchase unit to an EXISTING product (a new product got
    its unit inline at creation).

    Written through the product's own serializer, which rebuilds the whole unit
    list — so the existing units are re-sent alongside the new one. ``barcodes``
    is deliberately omitted per unit: the serializer keeps the stored packaging
    codes when the key is absent, and re-sending them would only risk tripping
    its own collision check.
    """
    from apps.catalog.models import ProductVariant
    from apps.catalog.views import ProductViewSet

    for line in plan.get("lines") or []:
        propose = line.get("unit_create")
        variant_id = line.get("variant_id")
        if not propose or not variant_id or line.get("create_ref"):
            continue
        variant = (
            ProductVariant.objects.filter(pk=variant_id).select_related("product").first()
        )
        if variant is None:
            continue
        product = variant.product
        if product.units.filter(unit__code=propose["unit"]).exists():
            continue
        units = [
            {
                "unit": product_unit.unit.code,
                "factor_to_base": format(product_unit.factor_to_base, "f"),
                "price": (
                    None if product_unit.price is None else format(product_unit.price, "f")
                ),
                "is_sellable": product_unit.is_sellable,
                "is_purchasable": product_unit.is_purchasable,
                "display_order": product_unit.display_order,
            }
            for product_unit in product.units.select_related("unit")
        ]
        units.append(
            {
                "unit": propose["unit"],
                "factor_to_base": propose["factor_to_base"],
                "is_purchasable": True,
            }
        )
        _dispatch(
            ProductViewSet,
            action="partial_update",
            method="patch",
            user=user,
            data={"units": units},
            kwargs={"pk": product.pk},
            stage="product_unit",
            line_index=line.get("line_index"),
        )


def _purchase_order_payload(plan, supplier, created, options):
    lines = []
    for line in plan.get("lines") or []:
        if line.get("skip"):
            continue
        variant_id = line.get("variant_id")
        if not variant_id and line.get("create_ref"):
            variant_id = (created.get(line["create_ref"]) or {}).get("variant_id")
        quantity = _decimal(line.get("quantity"))
        unit_cost = _decimal(line.get("unit_cost"))
        if not variant_id or quantity is None or quantity <= 0 or unit_cost is None:
            # The review card disables its footer on exactly this, but the rule
            # lives here too: an edited plan arrives straight from a client.
            raise IntakeApplyError.bad_request(
                "lines",
                {
                    "detail": (
                        "Every line needs a product, a quantity and a cost "
                        "before the invoice can be applied."
                    )
                },
                line_index=line.get("line_index"),
            )
        payload = {
            "variant": variant_id,
            "quantity": format(quantity.normalize(), "f"),
            "unit_cost": format(unit_cost.quantize(Decimal("0.01")), "f"),
        }
        # Only send a unit when it is a configured PURCHASE unit on the product;
        # the base unit is expressed by omitting it.
        unit_code = (line.get("unit") or "").strip()
        if unit_code:
            payload["unit"] = unit_code
        lines.append(payload)

    po_plan = plan.get("po") or {}
    payload = {
        "supplier": supplier.pk,
        "lines": lines,
        "notes": po_plan.get("notes") or "",
        "acknowledge_cost_warnings": bool(options.get("acknowledge_cost_warnings", True)),
    }
    if po_plan.get("supplier_invoice_number"):
        payload["supplier_invoice_number"] = po_plan["supplier_invoice_number"]
    if po_plan.get("supplier_invoice_date"):
        payload["supplier_invoice_date"] = po_plan["supplier_invoice_date"]
    currency = _resolvable_currency(po_plan.get("currency"))
    if currency:
        payload["currency"] = currency
    return payload


def _resolvable_currency(code):
    """A foreign currency is only carried onto the order when the shop actually
    has it and a rate can be found: an unresolvable rate is a hard 400 on the
    PO, and refusing the whole invoice over the currency line of a document that
    is priced in dinars anyway would be absurd."""
    code = (code or "").strip().upper()
    if not code:
        return None
    try:
        from apps.fx.models import Currency
        from apps.purchasing import currency as purchase_currency

        if not purchase_currency.is_foreign(code):
            return None
        if not Currency.objects.filter(pk=code, is_enabled=True).exists():
            return None
        if purchase_currency.resolve_order_rate(code) is None:
            return None
    except Exception:  # pragma: no cover - fx is optional at this seam
        logger.exception("Invoice intake currency resolution failed")
        return None
    return code


def _attach_pages(intake, purchase_order):
    """Re-point the photographed pages at the purchase order, so the image
    travels with the document that was created from it."""
    from django.contrib.contenttypes.models import ContentType

    from apps.attachments.models import Attachment

    pages = list(intake.pages.all())
    if not pages:
        return
    content_type = ContentType.objects.get_for_model(
        purchase_order, for_concrete_model=False
    )
    for page in pages:
        page.owner_content_type = content_type
        page.owner_object_id = purchase_order.pk
        page.role = Attachment.Role.SUPPLIER_INVOICE_SCAN
        page.save(
            update_fields=[
                "owner_content_type",
                "owner_object_id",
                "role",
                "updated_at",
            ]
        )


def _learn_aliases(plan, created):
    """Remember the supplier's wording for every confirmed match.

    Deterministic tiers are recorded as ``invoice``; a machine-adjudicated match
    (the supplier-history prior, and later the LLM tie-breaker) as
    ``ai_adjudicated``, so those can be weighted lower or revoked in bulk if a
    shop's matching ever goes wrong.
    """
    from apps.catalog.models import Product, ProductAlias, ProductVariant

    from .reconcile import MATCH_ALIAS, MATCH_BARCODE, MATCH_NAME, MATCH_UNIT_BARCODE

    deterministic = {MATCH_BARCODE, MATCH_UNIT_BARCODE, MATCH_ALIAS, MATCH_NAME}
    variant_ids = set()
    for line in plan.get("lines") or []:
        if line.get("variant_id"):
            variant_ids.add(line["variant_id"])
    products = {}
    if variant_ids:
        products = {
            variant.pk: variant.product
            for variant in ProductVariant.objects.filter(pk__in=variant_ids).select_related(
                "product"
            )
        }
    for line in plan.get("lines") or []:
        raw_name = (line.get("raw_name") or "").strip()
        if not raw_name or line.get("skip"):
            continue
        variant_id = line.get("variant_id")
        product = products.get(variant_id)
        if product is None and line.get("create_ref"):
            product_id = (created.get(line["create_ref"]) or {}).get("product_id")
            product = Product.objects.filter(pk=product_id).first()
        if product is None:
            continue
        source = (
            ProductAlias.Source.INVOICE
            if line.get("match_by") in deterministic or line.get("create_ref")
            else ProductAlias.Source.AI_ADJUDICATED
        )
        ProductAlias.remember(product, raw_name, source=source)


def _apply_options(purchase_order, supplier, *, user, options):
    """Submit / receive / pay, each through its own permission-gated action.

    Nothing here is implied: an intake creates a DRAFT unless the user asked for
    more, and each extra step is refused by the same permission that refuses it
    on the purchasing screen.
    """
    from apps.purchasing.views import PurchaseOrderViewSet, SupplierPaymentViewSet

    pk = {"pk": purchase_order.pk}
    if options.get("submit") or options.get("receive"):
        _dispatch(
            PurchaseOrderViewSet,
            action="submit",
            method="post",
            user=user,
            kwargs=pk,
            stage="submit",
        )
    if options.get("receive"):
        _dispatch(
            PurchaseOrderViewSet,
            action="receive",
            method="post",
            user=user,
            data={},
            kwargs=pk,
            stage="receive",
        )
    if options.get("pay"):
        purchase_order.refresh_from_db()
        amount = _decimal(options.get("amount")) or purchase_order.total
        _dispatch(
            SupplierPaymentViewSet,
            action="create",
            method="post",
            user=user,
            data={
                "supplier": supplier.pk,
                "purchase_order": purchase_order.pk,
                "amount": format(Decimal(amount).quantize(Decimal("0.01")), "f"),
                "method": options.get("method") or "cash",
                "paid_at": (options.get("paid_at") or timezone.now().date().isoformat()),
                "notes": "",
            },
            stage="payment",
        )


def apply_intake(intake, plan=None, *, user, options=None):
    """Create everything ``plan`` describes, as ``user``, in one transaction.

    Idempotent on the intake: applying an already-applied intake returns the
    purchase order it created, so a retried request (or a double-tapped button)
    cannot produce a second order for the same invoice.
    """
    options = dict(options or {})
    if intake.status == InvoiceIntake.Status.APPLIED and intake.purchase_order_id:
        return intake.purchase_order
    if intake.status == InvoiceIntake.Status.CANCELLED:
        raise IntakeApplyError.bad_request("intake", {"detail": "Intake is cancelled."})

    plan = plan if isinstance(plan, dict) and plan else intake.plan
    if not isinstance(plan, dict) or not plan.get("lines"):
        raise IntakeApplyError.bad_request("plan", {"detail": "Nothing to apply."})

    from apps.purchasing.models import PurchaseOrder
    from apps.purchasing.views import PurchaseOrderViewSet

    with transaction.atomic():
        supplier = _resolve_supplier(plan, user=user)
        created = _create_products(plan, user=user)
        _ensure_units(plan, created, user=user)
        payload = _purchase_order_payload(plan, supplier, created, options)
        data = _dispatch(
            PurchaseOrderViewSet,
            action="create",
            method="post",
            user=user,
            data=payload,
            stage="purchase_order",
        )
        purchase_order = PurchaseOrder.objects.get(pk=data["id"])
        _attach_pages(intake, purchase_order)
        _learn_aliases(plan, created)
        _apply_options(purchase_order, supplier, user=user, options=options)

        intake.plan = plan
        intake.supplier = supplier
        intake.purchase_order = purchase_order
        intake.status = InvoiceIntake.Status.APPLIED
        intake.error = ""
        intake.save(
            update_fields=[
                "plan",
                "supplier",
                "purchase_order",
                "status",
                "error",
                "updated_at",
            ]
        )
    purchase_order.refresh_from_db()
    return purchase_order


def cancel_intake(intake):
    """Abandon an intake. Applied intakes are never cancelled here — undoing a
    created purchase order is the PO's own cancel action, with its own
    permission and audit event."""
    if intake.status == InvoiceIntake.Status.APPLIED:
        raise IntakeApplyError.bad_request(
            "intake", {"detail": "An applied intake cannot be cancelled."}
        )
    intake.status = InvoiceIntake.Status.CANCELLED
    intake.save(update_fields=["status", "updated_at"])
    return intake
