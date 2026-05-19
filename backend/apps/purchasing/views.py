from rest_framework import mixins, serializers, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission
from .models import PurchaseOrder, Supplier, SupplierPayment
from .serializers import (
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
    submit_purchase_order,
)


class SupplierViewSet(viewsets.ModelViewSet):
    serializer_class = SupplierSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_supplier",),
        "retrieve": ("purchasing.view_supplier",),
        "create": ("purchasing.add_supplier",),
        "update": ("purchasing.change_supplier",),
        "partial_update": ("purchasing.change_supplier",),
        "destroy": ("purchasing.delete_supplier",),
    }
    queryset = Supplier.objects.all()
    filterset_fields = ("is_active",)
    search_fields = ("name", "contact_name", "phone", "email", "address")
    ordering_fields = ("name", "created_at", "updated_at")


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
        "create": ("purchasing.add_purchaseorder",),
        "submit": ("purchasing.change_purchaseorder",),
        "cancel": ("purchasing.change_purchaseorder",),
        "receive": (
            "purchasing.change_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "return_items": (
            "purchasing.change_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "refund_items": (
            "purchasing.change_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "exchange_items": (
            "purchasing.change_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "update": ("purchasing.change_purchaseorder",),
        "partial_update": ("purchasing.change_purchaseorder",),
        "destroy": ("purchasing.delete_purchaseorder",),
    }
    queryset = PurchaseOrder.objects.select_related("supplier").prefetch_related(
        "lines__product",
        "lines__receipt_lines",
        "receipts__lines__product",
        "receipts__created_by",
        "adjustments__lines__product",
        "adjustments__created_by",
        "adjustments__supplier_credit",
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
