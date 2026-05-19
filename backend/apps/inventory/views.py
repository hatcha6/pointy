from django.db import transaction
from rest_framework import mixins, serializers, viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission
from .models import StockItem, StockMovement
from .serializers import StockItemSerializer, StockMovementSerializer


class StockItemViewSet(viewsets.ModelViewSet):
    serializer_class = StockItemSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockitem",),
        "retrieve": ("inventory.view_stockitem",),
        "create": ("inventory.add_stockitem",),
        "update": ("inventory.change_stockitem",),
        "partial_update": ("inventory.change_stockitem",),
        "destroy": ("inventory.delete_stockitem",),
    }
    queryset = StockItem.objects.select_related("product")
    filterset_fields = ("product",)
    search_fields = ("product__sku", "product__barcode", "product__name")
    ordering_fields = ("quantity_on_hand", "updated_at")


class StockMovementViewSet(
    mixins.CreateModelMixin,
    mixins.RetrieveModelMixin,
    mixins.ListModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = StockMovementSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockmovement",),
        "retrieve": ("inventory.view_stockmovement",),
        "create": ("inventory.add_stockmovement",),
    }
    queryset = StockMovement.objects.select_related("product", "stock_item", "created_by")
    filterset_fields = ("product", "movement_type")
    search_fields = ("product__sku", "product__barcode", "product__name", "note")
    ordering_fields = ("created_at", "quantity", "movement_type")

    def perform_create(self, serializer):
        product = serializer.validated_data["product"]
        quantity = serializer.validated_data["quantity"]
        movement_type = serializer.validated_data["movement_type"]

        with transaction.atomic():
            stock_item, _ = StockItem.objects.select_for_update().get_or_create(
                product=product,
            )
            before = {
                "on_hand": stock_item.quantity_on_hand,
                "committed": stock_item.quantity_committed,
                "expected": stock_item.quantity_expected,
            }
            after = self._apply_movement(stock_item, movement_type, quantity)
            stock_item.save(
                update_fields=[
                    "quantity_on_hand",
                    "quantity_committed",
                    "quantity_expected",
                    "updated_at",
                ],
            )
            serializer.save(
                stock_item=stock_item,
                created_by=self.request.user,
                on_hand_before=before["on_hand"],
                on_hand_after=after["on_hand"],
                committed_before=before["committed"],
                committed_after=after["committed"],
                expected_before=before["expected"],
                expected_after=after["expected"],
            )

    def _apply_movement(self, stock_item, movement_type, quantity):
        if movement_type == StockMovement.Type.INCREASE:
            stock_item.quantity_on_hand += quantity
        elif movement_type == StockMovement.Type.EXPECTED:
            stock_item.quantity_expected += quantity
        elif movement_type == StockMovement.Type.RECEIVE_EXPECTED:
            stock_item.quantity_on_hand += quantity
            stock_item.quantity_expected -= quantity
        elif movement_type == StockMovement.Type.RECEIVE_DAMAGED:
            stock_item.quantity_expected -= quantity
        elif movement_type == StockMovement.Type.CANCEL_EXPECTED:
            stock_item.quantity_expected -= quantity
        elif movement_type in (
            StockMovement.Type.DECREASE,
            StockMovement.Type.DAMAGED,
        ):
            stock_item.quantity_on_hand -= quantity

        if stock_item.quantity_on_hand < 0:
            raise serializers.ValidationError(
                {"quantity": "Stock on hand cannot become negative."}
            )
        if stock_item.quantity_expected < 0:
            raise serializers.ValidationError(
                {"quantity": "Expected stock cannot become negative."}
            )

        return {
            "on_hand": stock_item.quantity_on_hand,
            "committed": stock_item.quantity_committed,
            "expected": stock_item.quantity_expected,
        }
