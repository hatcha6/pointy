from django.core.cache import cache
from rest_framework import viewsets

from .models import Product
from .serializers import ProductSerializer


class ProductViewSet(viewsets.ModelViewSet):
    serializer_class = ProductSerializer
    queryset = Product.objects.all()
    filterset_fields = ("is_active",)
    search_fields = ("sku", "barcode", "name")
    ordering_fields = ("name", "unit_price", "updated_at")

    def get_queryset(self):
        cache_key = "catalog:active_product_ids"
        if self.request.query_params.get("is_active") == "true":
            product_ids = cache.get(cache_key)
            if product_ids is None:
                product_ids = list(Product.objects.filter(is_active=True).values_list("id", flat=True))
                cache.set(cache_key, product_ids, timeout=60)
            return Product.objects.filter(id__in=product_ids)
        return super().get_queryset()
