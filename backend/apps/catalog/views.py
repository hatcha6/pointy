from django.core.cache import cache
from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission
from .models import Product
from .serializers import ProductSerializer


class ProductViewSet(viewsets.ModelViewSet):
    active_cache_key = "catalog:active_product_ids"
    serializer_class = ProductSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_product",),
        "retrieve": ("catalog.view_product",),
        "create": ("catalog.add_product",),
        "update": ("catalog.change_product",),
        "partial_update": ("catalog.change_product",),
        "destroy": ("catalog.delete_product",),
    }
    queryset = Product.objects.all()
    filterset_fields = ("is_active",)
    search_fields = ("sku", "barcode", "name")
    ordering_fields = ("name", "unit_price", "created_at", "updated_at")

    def get_queryset(self):
        if self.request.query_params.get("is_active") == "true":
            product_ids = self._get_active_product_ids()
            if product_ids is None:
                product_ids = list(
                    Product.objects.filter(is_active=True).values_list("id", flat=True)
                )
                self._set_active_product_ids(product_ids)
            return Product.objects.filter(id__in=product_ids)
        return super().get_queryset()

    def perform_create(self, serializer):
        product = serializer.save()
        self._clear_catalog_cache()
        return product

    def perform_update(self, serializer):
        product = serializer.save()
        self._clear_catalog_cache()
        return product

    def perform_destroy(self, instance):
        super().perform_destroy(instance)
        self._clear_catalog_cache()

    def _clear_catalog_cache(self):
        try:
            cache.delete(self.active_cache_key)
        except Exception:
            pass

    def _get_active_product_ids(self):
        try:
            return cache.get(self.active_cache_key)
        except Exception:
            return None

    def _set_active_product_ids(self, product_ids):
        try:
            cache.set(self.active_cache_key, product_ids, timeout=60)
        except Exception:
            pass
