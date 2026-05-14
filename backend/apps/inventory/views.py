from rest_framework import viewsets

from .models import StockItem
from .serializers import StockItemSerializer


class StockItemViewSet(viewsets.ModelViewSet):
    serializer_class = StockItemSerializer
    queryset = StockItem.objects.select_related("product")
    search_fields = ("product__sku", "product__barcode", "product__name")
    ordering_fields = ("quantity_on_hand", "updated_at")
