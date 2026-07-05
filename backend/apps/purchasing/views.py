from decimal import Decimal

from django.db.models import (
    Avg,
    Count,
    DecimalField,
    F,
    Max,
    Min,
    OuterRef,
    Prefetch,
    Q,
    Subquery,
    Sum,
    Value,
)
from django.db.models.functions import Coalesce
from rest_framework import mixins, parsers, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSerializer, AttachmentSummarySerializer
from apps.catalog.models import Product, ProductVariant, VariantOptionValue
from apps.core.idempotency import run_idempotent_request
from apps.core.permissions import HasPointyPermission
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    Supplier,
    SupplierPayment,
)
from .serializers import (
    ProductCostHistorySerializer,
    PurchaseAdjustmentHistorySerializer,
    PurchaseDiscountPreviewSerializer,
    PurchaseOrderExchangeSerializer,
    PurchaseOrderRefundSerializer,
    PurchaseReceiptInputSerializer,
    PurchaseOrderReturnSerializer,
    PurchaseOrderListSerializer,
    PurchaseOrderSerializer,
    SupplierPaymentSerializer,
    SupplierSerializer,
)
from .services import (
    cancel_purchase_order,
    clear_purchase_order_applied_discounts,
    latest_purchase_line_for_variant,
    receive_purchase_order,
    record_purchase_order_audit_event,
    submit_purchase_order,
)


class SupplierViewSet(viewsets.ModelViewSet):
    serializer_class = SupplierSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_supplier",),
        "retrieve": ("purchasing.view_supplier",),
        "purchase_history": ("purchasing.view_supplier",),
        "create": ("purchasing.add_supplier",),
        "update": ("purchasing.change_supplier",),
        "partial_update": ("purchasing.change_supplier",),
        "destroy": ("purchasing.delete_supplier",),
    }
    queryset = Supplier.objects.all()
    filterset_fields = ("is_active",)
    search_fields = ("name", "contact_name", "phone", "email", "address")
    ordering_fields = ("name", "created_at", "updated_at")

    def get_queryset(self):
        # Annotate the purchase totals/counts the serializer needs so a list of
        # suppliers does not run an aggregate + count per row.
        not_cancelled = ~Q(
            purchase_orders__status=PurchaseOrder.Status.CANCELLED,
        )
        return (
            super()
            .get_queryset()
            .annotate(
                purchases_total=Sum("purchase_orders__total", filter=not_cancelled),
                purchases_count=Count("purchase_orders", filter=not_cancelled),
            )
            # Reassert the supplier ordering: aggregating over purchase_orders
            # otherwise leaks that model's default ordering into the GROUP BY,
            # which reorders the list and can split multi-order suppliers into
            # duplicate rows.
            .order_by("name")
        )

    @action(detail=True, methods=["get"], url_path="purchase-history")
    def purchase_history(self, request, pk=None):
        supplier = self.get_object()
        queryset = PurchaseOrderViewSet.queryset.filter(supplier=supplier).order_by(
            "-created_at", "-id"
        )
        page = self.paginate_queryset(queryset)
        serializer = PurchaseOrderSerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)


class SupplierPaymentViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = SupplierPaymentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_supplierpayment",),
        "retrieve": ("purchasing.view_supplierpayment",),
        "create": ("purchasing.add_supplierpayment",),
    }
    queryset = SupplierPayment.objects.select_related(
        "supplier",
        "purchase_order",
        "created_by",
    )
    # Dict form so ``paid_at`` exposes range/day lookups for the Payments hub
    # (money-OUT date window), mirroring PaymentViewSet/OrderViewSet.
    filterset_fields = {
        "supplier": ["exact"],
        "purchase_order": ["exact"],
        "method": ["exact"],
        "paid_at": ["exact", "gte", "lte", "date"],
    }
    search_fields = (
        "supplier__name",
        "purchase_order__order_number",
        "reference",
        "notes",
    )
    ordering_fields = ("paid_at", "created_at", "amount")

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(SupplierPaymentViewSet, self).create(
                request,
                *args,
                **kwargs,
            ),
        )


class PurchaseOrderViewSet(viewsets.ModelViewSet):
    serializer_class = PurchaseOrderSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_purchaseorder",),
        "retrieve": ("purchasing.view_purchaseorder",),
        "last_cost": ("purchasing.view_purchaseorder",),
        "variant_last_cost": ("purchasing.view_purchaseorder",),
        "discount_preview": ("purchasing.add_purchaseorder",),
        "product_cost_history": ("purchasing.view_purchaseorder",),
        "variant_cost_history": ("purchasing.view_purchaseorder",),
        "product_margin_impact": ("purchasing.view_purchaseorder",),
        "variant_margin_impact": ("purchasing.view_purchaseorder",),
        "product_cost_summary": ("purchasing.view_purchaseorder",),
        "outstanding_received_not_paid": ("purchasing.view_purchaseorder",),
        "adjustment_history": ("purchasing.view_purchaseorder",),
        "attachments": ("purchasing.view_purchaseorder", "attachments.view_attachment"),
        "create": ("purchasing.add_purchaseorder",),
        "submit": ("purchasing.edit_draft_purchaseorder",),
        "cancel": ("purchasing.cancel_purchaseorder",),
        "receive": (
            "purchasing.receive_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "return_items": (
            "purchasing.adjust_received_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "refund_items": (
            "purchasing.adjust_received_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "exchange_items": (
            "purchasing.adjust_received_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "update": ("purchasing.edit_draft_purchaseorder",),
        "partial_update": ("purchasing.edit_draft_purchaseorder",),
        "destroy": ("purchasing.delete_purchaseorder",),
    }
    queryset = PurchaseOrder.objects.select_related("supplier").prefetch_related(
        "lines__variant__product",
        "lines__receipt_lines",
        "landed_cost_entries",
        "receipts__lines__variant__product",
        "receipts__created_by",
        "adjustments__lines__variant__product",
        "adjustments__replacement_lines__variant__product",
        "adjustments__created_by",
        "adjustments__supplier_credit",
        "audit_events__created_by",
        "supplier_payments",
        "supplier_credits",
        "attachments",
    )
    filterset_fields = {
        "status": ["exact"],
        "supplier": ["exact"],
        "created_at": ["exact", "gte", "lte", "date"],
    }
    search_fields = (
        "order_number",
        "supplier__name",
        "supplier_invoice_number",
        "lines__variant__product__name",
        "lines__variant__sku",
        "lines__variant__barcode",
    )
    ordering_fields = (
        "created_at",
        "updated_at",
        "total",
        "order_number",
        "supplier_invoice_date",
    )

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(PurchaseOrderViewSet, self).create(
                request,
                *args,
                **kwargs,
            ),
        )

    @action(detail=False, methods=["get"], url_path="last-cost")
    def last_cost(self, request):
        return self._last_cost_response(request)

    def get_required_permissions(self, request):
        if self.action == "attachments" and request.method == "POST":
            return ("purchasing.view_purchaseorder", "attachments.add_attachment")
        return self.permission_map.get(self.action)

    # Read-only list-shaped actions: the payables strip endpoint serves the
    # same row summaries as the main list, so both share the lightweight
    # serializer and the trimmed prefetches below.
    _list_shaped_actions = ("list", "outstanding_received_not_paid")

    def get_serializer_class(self):
        if self.action in self._list_shaped_actions:
            return PurchaseOrderListSerializer
        return PurchaseOrderSerializer

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.action in self._list_shaped_actions:
            # The list serializer omits the receipt/adjustment/audit/attachment
            # trees, so drop those prefetches and keep only what the summary,
            # line count, and balance need. The line queryset carries the
            # previous-cost annotation so the serializer's unit-cost-change
            # fields do not run one lookup query per line.
            queryset = queryset.prefetch_related(None).prefetch_related(
                Prefetch(
                    "lines",
                    queryset=PurchaseLine.objects.select_related(
                        "variant__product"
                    )
                    .prefetch_related(
                        Prefetch(
                            "variant__option_values",
                            queryset=VariantOptionValue.objects.select_related(
                                "option"
                            ),
                        ),
                        "receipt_lines",
                        "adjustment_lines",
                    )
                    .annotate(
                        previous_unit_cost_value=Subquery(
                            PurchaseLine.objects.filter(
                                variant_id=OuterRef("variant_id"),
                                created_at__lt=OuterRef("created_at"),
                            )
                            .exclude(
                                purchase_order__status=PurchaseOrder.Status.CANCELLED
                            )
                            .order_by("-created_at", "-id")
                            .values("unit_cost")[:1]
                        )
                    ),
                ),
                "supplier_payments",
                "supplier_credits",
            )
        product_id = self.request.query_params.get("product")
        variant_id = self.request.query_params.get("variant")
        if product_id:
            queryset = queryset.filter(lines__variant__product_id=product_id)
        if variant_id:
            queryset = queryset.filter(lines__variant_id=variant_id)
        if product_id or variant_id:
            queryset = queryset.distinct()
        return queryset

    @action(detail=False, methods=["get"], url_path="variant-last-cost")
    def variant_last_cost(self, request):
        return self._last_cost_response(request)

    def _last_cost_response(self, request):
        product_id = request.query_params.get("product")
        variant_id = request.query_params.get("variant")
        if not variant_id:
            raise serializers.ValidationError({"variant": "Variant is required."})

        variant = self._get_variant(variant_id)
        if product_id and str(variant.product_id) != str(product_id):
            raise serializers.ValidationError(
                {"variant": "Variant does not belong to the selected product."}
            )
        line = latest_purchase_line_for_variant(variant.pk)
        return Response(
            {
                "product": variant.product_id,
                "product_id": variant.product_id,
                "variant": variant.pk,
                "variant_id": variant.pk,
                "unit_cost": None if line is None else line.unit_cost,
            }
        )

    @action(detail=False, methods=["post"], url_path="discount-preview")
    def discount_preview(self, request):
        serializer = PurchaseDiscountPreviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return Response(serializer.preview_data)

    @action(detail=False, methods=["get"], url_path="product-cost-history")
    def product_cost_history(self, request):
        return self._cost_history_response()

    @action(detail=False, methods=["get"], url_path="variant-cost-history")
    def variant_cost_history(self, request):
        if not self.request.query_params.get("variant"):
            raise serializers.ValidationError({"variant": "Variant is required."})
        return self._cost_history_response()

    def _cost_history_response(self):
        variant = self._get_optional_variant()
        product = variant.product if variant is not None else self._get_required_product()
        queryset = (
            PurchaseLine.objects.filter(variant__product=product)
            .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
            .select_related("purchase_order__supplier", "variant", "variant__product")
            .order_by("-created_at", "-id")
        )
        if variant is not None:
            queryset = queryset.filter(variant=variant)
        page = self.paginate_queryset(queryset)
        serializer = ProductCostHistorySerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    @action(detail=False, methods=["get"], url_path="product-margin-impact")
    def product_margin_impact(self, request):
        return self._margin_impact_response()

    @action(detail=False, methods=["get"], url_path="variant-margin-impact")
    def variant_margin_impact(self, request):
        return self._margin_impact_response()

    def _margin_impact_response(self):
        variant = self._get_optional_variant()
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        product = variant.product
        latest_line = latest_purchase_line_for_variant(variant.pk)
        previous_line = (
            None
            if latest_line is None
            else latest_purchase_line_for_variant(variant.pk, before_line=latest_line)
        )
        return Response(
            product_margin_impact_payload(
                product=product,
                variant=variant,
                latest_line=latest_line,
                previous_line=previous_line,
            )
        )

    @action(detail=False, methods=["get"], url_path="product-cost-summary")
    def product_cost_summary(self, request):
        """Per-variant lowest/highest/last/average cost for a product.

        Powers the "Lowest / Highest / Last cost" metrics on the product &
        variant detail screens and the Change-prices dialog. Costs are derived
        from received purchase history (excluding cancelled POs); ``last_cost``
        uses the most recent line so it can differ from the lowest/highest.
        """
        product = self._get_required_product()
        variants = list(product.variants.all().order_by("-is_default", "name", "id"))
        lines = PurchaseLine.objects.filter(variant__product=product).exclude(
            purchase_order__status=PurchaseOrder.Status.CANCELLED
        )
        stats_by_variant = {
            row["variant_id"]: row
            for row in lines.values("variant_id").annotate(
                lowest_cost=Min("effective_unit_cost"),
                highest_cost=Max("effective_unit_cost"),
                average_cost=Avg("effective_unit_cost"),
                purchases_count=Count("id"),
            )
        }
        payload = []
        for variant in variants:
            stats = stats_by_variant.get(variant.pk)
            last_line = latest_purchase_line_for_variant(variant.pk)
            payload.append(
                {
                    "product": product.pk,
                    "variant": variant.pk,
                    "variant_name": variant.display_name,
                    "unit_price": variant.unit_price,
                    "lowest_cost": stats["lowest_cost"] if stats else None,
                    "highest_cost": stats["highest_cost"] if stats else None,
                    "average_cost": stats["average_cost"] if stats else None,
                    "last_cost": None if last_line is None else last_line.effective_unit_cost,
                    "purchases_count": stats["purchases_count"] if stats else 0,
                }
            )
        return Response(payload)

    @action(detail=False, methods=["get"], url_path="outstanding-received-not-paid")
    def outstanding_received_not_paid(self, request):
        # Filter, sort, and paginate in SQL — loading every received order to
        # compute ``balance_due`` in Python hangs the purchases screen once the
        # table grows (each order also drags its prefetch trees along).
        # ``balance_due > 0`` is ``total > sum(all supplier payments)`` because
        # paid_total + credit_applied_total together cover every payment method.
        # A correlated subquery keeps that sum immune to row inflation from any
        # multi-valued joins (e.g. the product/variant line filters).
        paid = (
            SupplierPayment.objects.filter(purchase_order=OuterRef("pk"))
            .order_by()
            .values("purchase_order")
            .annotate(total=Sum("amount"))
            .values("total")[:1]
        )
        money = DecimalField(max_digits=10, decimal_places=2)
        queryset = (
            self.get_queryset()
            .filter(status=PurchaseOrder.Status.RECEIVED)
            .annotate(
                paid_amount=Coalesce(
                    Subquery(paid, output_field=money),
                    Value(Decimal("0.00")),
                    output_field=money,
                )
            )
            .filter(total__gt=F("paid_amount"))
            # Most urgent first: dated orders by earliest due date, undated ones
            # last, most recently received breaking ties.
            .order_by(
                F("due_date").asc(nulls_last=True),
                Coalesce("received_at", "created_at").desc(),
                "-id",
            )
        )
        page = self.paginate_queryset(queryset)
        serializer = self.get_serializer(
            page if page is not None else queryset,
            many=True,
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    @action(detail=False, methods=["get"], url_path="adjustment-history")
    def adjustment_history(self, request):
        adjustment_type = request.query_params.get("adjustment_type")
        queryset = (
            PurchaseOrderAdjustmentLine.objects.select_related(
                "adjustment__purchase_order__supplier",
                "purchase_line",
                "variant",
                "variant__product",
            )
            .filter(
                adjustment__adjustment_type__in=(
                    PurchaseOrderAdjustment.AdjustmentType.RETURN,
                    PurchaseOrderAdjustment.AdjustmentType.REFUND,
                )
            )
            .order_by("-adjustment__created_at", "-adjustment_id", "-id")
        )
        if adjustment_type:
            if adjustment_type not in (
                PurchaseOrderAdjustment.AdjustmentType.RETURN,
                PurchaseOrderAdjustment.AdjustmentType.REFUND,
            ):
                raise serializers.ValidationError({"adjustment_type": "Use return or refund."})
            queryset = queryset.filter(adjustment__adjustment_type=adjustment_type)
        supplier_id = request.query_params.get("supplier")
        if supplier_id:
            queryset = queryset.filter(
                adjustment__purchase_order__supplier_id=supplier_id,
            )
        variant_id = request.query_params.get("variant")
        if variant_id:
            variant = self._get_variant(variant_id)
            product_id = request.query_params.get("product")
            if product_id and str(variant.product_id) != str(product_id):
                raise serializers.ValidationError(
                    {"variant": "Variant does not belong to the selected product."}
                )
            queryset = queryset.filter(variant=variant)
        else:
            product_id = request.query_params.get("product")
            if product_id:
                queryset = queryset.filter(variant__product_id=product_id)

        page = self.paginate_queryset(queryset)
        serializer = PurchaseAdjustmentHistorySerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    @action(
        detail=True,
        methods=["get", "post"],
        url_path="attachments",
        parser_classes=[parsers.MultiPartParser, parsers.FormParser, parsers.JSONParser],
    )
    def attachments(self, request, pk=None):
        purchase_order = self.get_object()
        if request.method.lower() == "post":
            return self._create_attachment_for_purchase_order(request, purchase_order)

        queryset = purchase_order.attachments.active().select_related(
            "owner_content_type",
            "storage_volume",
            "created_by",
        )
        serializer = AttachmentSummarySerializer(
            queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        return Response(serializer.data)

    def _create_attachment_for_purchase_order(self, request, purchase_order):
        data = request.data.copy()
        data.setdefault("role", Attachment.Role.SUPPLIER_INVOICE_SCAN)
        serializer = AttachmentSerializer(
            data=data,
            context={**self.get_serializer_context(), "owner": purchase_order},
        )
        serializer.is_valid(raise_exception=True)
        attachment = serializer.save()
        return Response(
            AttachmentSummarySerializer(
                attachment,
                context=self.get_serializer_context(),
            ).data,
            status=status.HTTP_201_CREATED,
        )

    def _get_required_product(self):
        product_id = self.request.query_params.get("product")
        if not product_id:
            raise serializers.ValidationError({"product": "Product is required."})
        return self._get_product(product_id)

    def _get_product(self, product_id):
        try:
            return Product.objects.get(pk=product_id)
        except (Product.DoesNotExist, ValueError):
            raise serializers.ValidationError({"product": "Product does not exist."})

    def _get_variant(self, variant_id):
        try:
            return ProductVariant.objects.select_related("product").get(pk=variant_id)
        except (ProductVariant.DoesNotExist, ValueError):
            raise serializers.ValidationError({"variant": "Variant does not exist."})

    def _get_optional_variant(self):
        variant_id = self.request.query_params.get("variant")
        if not variant_id:
            return None
        variant = self._get_variant(variant_id)
        product_id = self.request.query_params.get("product")
        if product_id and str(variant.product_id) != str(product_id):
            raise serializers.ValidationError(
                {"variant": "Variant does not belong to the selected product."}
            )
        return variant

    @action(detail=True, methods=["post"])
    def submit(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._submit(request),
        )

    def _submit(self, request):
        purchase_order = submit_purchase_order(self.get_object(), request=request)
        return Response(
            self.get_serializer(purchase_order).data,
        )

    @action(detail=True, methods=["post"])
    def receive(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._receive(request),
        )

    def _receive(self, request):
        lines_data = None
        notes = ""
        if request.data:
            serializer = PurchaseReceiptInputSerializer(
                data=request.data,
                context={"purchase_order": self.get_object()},
            )
            serializer.is_valid(raise_exception=True)
            lines_data = serializer.validated_data["validated_lines"]
            notes = serializer.validated_data.get("notes", "")
        purchase_order = receive_purchase_order(
            self.get_object(),
            request=request,
            lines_data=lines_data,
            notes=notes,
        )
        return Response(
            self.get_serializer(purchase_order).data,
        )

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._cancel(request),
        )

    def _cancel(self, request):
        purchase_order = cancel_purchase_order(self.get_object(), request=request)
        return Response(
            self.get_serializer(purchase_order).data,
        )

    @action(detail=True, methods=["post"], url_path="return-items")
    def return_items(self, request, pk=None):
        return self._adjust_items(request, PurchaseOrderReturnSerializer)

    @action(detail=True, methods=["post"], url_path="refund-items")
    def refund_items(self, request, pk=None):
        return self._adjust_items(request, PurchaseOrderRefundSerializer)

    @action(detail=True, methods=["post"], url_path="exchange-items")
    def exchange_items(self, request, pk=None):
        return self._adjust_items(request, PurchaseOrderExchangeSerializer)

    def _adjust_items(self, request, serializer_class):
        return run_idempotent_request(
            request,
            lambda: self._adjust_items_once(request, serializer_class),
        )

    def _adjust_items_once(self, request, serializer_class):
        purchase_order = self.get_object()
        serializer = serializer_class(
            data=request.data,
            context={"purchase_order": purchase_order, "request": request},
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        purchase_order.refresh_from_db()
        return Response(self.get_serializer(purchase_order).data)

    def destroy(self, request, *args, **kwargs):
        purchase_order = self.get_object()
        if purchase_order.status != PurchaseOrder.Status.DRAFT:
            raise serializers.ValidationError(
                {"detail": "Only draft purchase orders can be deleted."}
            )
        record_purchase_order_audit_event(
            purchase_order,
            "deleted",
            request=request,
        )
        clear_purchase_order_applied_discounts(purchase_order)
        purchase_order.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


def money_string(value):
    return None if value is None else str(value.quantize(Decimal("0.01")))


def margin_amount(variant, line):
    if line is None:
        return None
    return (variant.unit_price - line.effective_unit_cost).quantize(Decimal("0.01"))


def margin_percent(variant, line):
    amount = margin_amount(variant, line)
    if amount is None or variant.unit_price == Decimal("0.00"):
        return None
    return (amount / variant.unit_price * Decimal("100")).quantize(Decimal("0.01"))


def decimal_delta(latest, previous):
    if latest is None or previous is None:
        return None
    return (latest - previous).quantize(Decimal("0.01"))


def product_margin_impact_payload(*, product, variant, latest_line, previous_line):
    latest_margin_amount = margin_amount(variant, latest_line)
    previous_margin_amount = margin_amount(variant, previous_line)
    latest_margin_percent = margin_percent(variant, latest_line)
    previous_margin_percent = margin_percent(variant, previous_line)
    latest_effective_cost = None if latest_line is None else latest_line.effective_unit_cost
    previous_effective_cost = None if previous_line is None else previous_line.effective_unit_cost
    latest_unit_cost = None if latest_line is None else latest_line.unit_cost
    previous_unit_cost = None if previous_line is None else previous_line.unit_cost
    return {
        "product": product.pk,
        "variant": variant.pk,
        "product_name": product.name,
        "variant_name": variant.display_name,
        "unit_price": money_string(variant.unit_price),
        "latest_purchase_line": None if latest_line is None else latest_line.pk,
        "latest_unit_cost": money_string(latest_unit_cost),
        "effective_unit_cost": money_string(latest_effective_cost),
        "latest_effective_unit_cost": money_string(latest_effective_cost),
        "latest_margin_amount": money_string(latest_margin_amount),
        "latest_margin_percent": money_string(latest_margin_percent),
        "previous_purchase_line": None if previous_line is None else previous_line.pk,
        "previous_unit_cost": money_string(previous_unit_cost),
        "previous_effective_unit_cost": money_string(previous_effective_cost),
        "previous_margin_amount": money_string(previous_margin_amount),
        "previous_margin_percent": money_string(previous_margin_percent),
        "unit_cost_delta": money_string(decimal_delta(latest_unit_cost, previous_unit_cost)),
        "effective_unit_cost_delta": money_string(
            decimal_delta(latest_effective_cost, previous_effective_cost)
        ),
        "margin_amount_delta": money_string(
            decimal_delta(latest_margin_amount, previous_margin_amount)
        ),
        "margin_percent_delta": money_string(
            decimal_delta(latest_margin_percent, previous_margin_percent)
        ),
    }


