from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission
from .models import StockItem
from .serializers import StockItemSerializer


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
    search_fields = ("product__sku", "product__barcode", "product__name")
    ordering_fields = ("quantity_on_hand", "updated_at")
