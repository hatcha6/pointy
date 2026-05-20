from datetime import date
from decimal import Decimal

from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.catalog.models import Product
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
    PurchaseOrderExchangeSerializer,
    PurchaseOrderRefundSerializer,
    PurchaseReceiptInputSerializer,
    PurchaseOrderReturnSerializer,
    PurchaseOrderSerializer,
    SupplierPaymentSerializer,
    SupplierSerializer,
)
from .services import (
    cancel_purchase_order,
    latest_purchase_line_for_product,
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

    @action(detail=True, methods=["get"], url_path="purchase-history")
    def purchase_history(self, request, pk=None):
        supplier = self.get_object()
        queryset = (
            PurchaseOrderViewSet.queryset.filter(supplier=supplier)
            .order_by("-created_at", "-id")
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
    filterset_fields = ("supplier", "purchase_order", "method")
    search_fields = (
        "supplier__name",
        "purchase_order__order_number",
        "reference",
        "notes",
    )
    ordering_fields = ("paid_at", "created_at", "amount")


class PurchaseOrderViewSet(viewsets.ModelViewSet):
    serializer_class = PurchaseOrderSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_purchaseorder",),
        "retrieve": ("purchasing.view_purchaseorder",),
        "last_cost": ("purchasing.view_purchaseorder",),
        "product_cost_history": ("purchasing.view_purchaseorder",),
        "product_margin_impact": ("purchasing.view_purchaseorder",),
        "outstanding_received_not_paid": ("purchasing.view_purchaseorder",),
        "adjustment_history": ("purchasing.view_purchaseorder",),
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
        "lines__product",
        "lines__receipt_lines",
        "receipts__lines__product",
        "receipts__created_by",
        "adjustments__lines__product",
        "adjustments__replacement_lines__product",
        "adjustments__created_by",
        "adjustments__supplier_credit",
        "audit_events__created_by",
        "supplier_payments",
        "supplier_credits",
    )
    filterset_fields = ("status", "supplier")
    search_fields = (
        "order_number",
        "supplier__name",
        "supplier_invoice_number",
        "lines__product__name",
        "lines__product__sku",
    )
    ordering_fields = (
        "created_at",
        "updated_at",
        "total",
        "order_number",
        "supplier_invoice_date",
    )

    @action(detail=False, methods=["get"], url_path="last-cost")
    def last_cost(self, request):
        product_id = request.query_params.get("product")
        if not product_id:
            raise serializers.ValidationError({"product": "Product is required."})

        line = latest_purchase_line_for_product(product_id)
        return Response(
            {
                "product": int(product_id),
                "unit_cost": None if line is None else line.unit_cost,
            }
        )

    @action(detail=False, methods=["get"], url_path="product-cost-history")
    def product_cost_history(self, request):
        product = self._get_required_product()
        queryset = (
            PurchaseLine.objects.filter(product=product)
            .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
            .select_related("purchase_order__supplier")
            .order_by("-created_at", "-id")
        )
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
        product = self._get_required_product()
        latest_line = latest_purchase_line_for_product(product.pk)
        previous_line = (
            None
            if latest_line is None
            else latest_purchase_line_for_product(product.pk, before_line=latest_line)
        )
        return Response(
            product_margin_impact_payload(
                product=product,
                latest_line=latest_line,
                previous_line=previous_line,
            )
        )

    @action(detail=False, methods=["get"], url_path="outstanding-received-not-paid")
    def outstanding_received_not_paid(self, request):
        queryset = self.get_queryset().filter(status=PurchaseOrder.Status.RECEIVED)
        purchase_orders = [
            purchase_order
            for purchase_order in queryset
            if purchase_order.balance_due > Decimal("0.00")
        ]
        purchase_orders.sort(key=outstanding_purchase_order_sort_key)
        page = self.paginate_queryset(purchase_orders)
        serializer = self.get_serializer(
            page if page is not None else purchase_orders,
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
                "product",
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
                raise serializers.ValidationError(
                    {"adjustment_type": "Use return or refund."}
                )
            queryset = queryset.filter(adjustment__adjustment_type=adjustment_type)
        supplier_id = request.query_params.get("supplier")
        if supplier_id:
            queryset = queryset.filter(
                adjustment__purchase_order__supplier_id=supplier_id,
            )
        product_id = request.query_params.get("product")
        if product_id:
            queryset = queryset.filter(product_id=product_id)

        page = self.paginate_queryset(queryset)
        serializer = PurchaseAdjustmentHistorySerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    def _get_required_product(self):
        product_id = self.request.query_params.get("product")
        if not product_id:
            raise serializers.ValidationError({"product": "Product is required."})
        try:
            return Product.objects.get(pk=product_id)
        except (Product.DoesNotExist, ValueError):
            raise serializers.ValidationError({"product": "Product does not exist."})

    @action(detail=True, methods=["post"])
    def submit(self, request, pk=None):
        purchase_order = submit_purchase_order(self.get_object(), request=request)
        return Response(
            self.get_serializer(purchase_order).data,
        )

    @action(detail=True, methods=["post"])
    def receive(self, request, pk=None):
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
        purchase_order.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


def money_string(value):
    return None if value is None else str(value.quantize(Decimal("0.01")))


def margin_amount(product, line):
    if line is None:
        return None
    return (product.unit_price - line.effective_unit_cost).quantize(Decimal("0.01"))


def margin_percent(product, line):
    amount = margin_amount(product, line)
    if amount is None or product.unit_price == Decimal("0.00"):
        return None
    return (amount / product.unit_price * Decimal("100")).quantize(Decimal("0.01"))


def decimal_delta(latest, previous):
    if latest is None or previous is None:
        return None
    return (latest - previous).quantize(Decimal("0.01"))


def product_margin_impact_payload(*, product, latest_line, previous_line):
    latest_margin_amount = margin_amount(product, latest_line)
    previous_margin_amount = margin_amount(product, previous_line)
    latest_margin_percent = margin_percent(product, latest_line)
    previous_margin_percent = margin_percent(product, previous_line)
    latest_effective_cost = (
        None if latest_line is None else latest_line.effective_unit_cost
    )
    previous_effective_cost = (
        None if previous_line is None else previous_line.effective_unit_cost
    )
    latest_unit_cost = None if latest_line is None else latest_line.unit_cost
    previous_unit_cost = None if previous_line is None else previous_line.unit_cost
    return {
        "product": product.pk,
        "product_name": product.name,
        "unit_price": money_string(product.unit_price),
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
        "unit_cost_delta": money_string(
            decimal_delta(latest_unit_cost, previous_unit_cost)
        ),
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


def outstanding_purchase_order_sort_key(purchase_order):
    due_date = purchase_order.due_date or date.max
    recency = purchase_order.received_at or purchase_order.created_at
    return (
        purchase_order.due_date is None,
        due_date,
        -recency.timestamp(),
        -purchase_order.pk,
    )
