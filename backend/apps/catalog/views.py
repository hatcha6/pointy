from django.core.cache import cache
from django.db.models import Count, Value
from django.db.models.functions import Coalesce
from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission
from .models import Product, ProductCategory
from .serializers import ProductCategorySerializer, ProductSerializer


class ProductCategoryViewSet(viewsets.ModelViewSet):
    serializer_class = ProductCategorySerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_productcategory",),
        "retrieve": ("catalog.view_productcategory",),
        "create": ("catalog.add_productcategory",),
        "update": ("catalog.change_productcategory",),
        "partial_update": ("catalog.change_productcategory",),
        "destroy": ("catalog.delete_productcategory",),
    }
    queryset = ProductCategory.objects.all()
    filterset_fields = ("is_active", "parent")
    search_fields = ("name", "description")
    ordering_fields = ("name", "created_at", "updated_at")

    def get_queryset(self):
        return (
            super()
            .get_queryset()
            .annotate(children_count=Count("children"))
            .order_by("name", "id")
        )


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
    queryset = Product.objects.prefetch_related("categories")
    filterset_fields = ("is_active", "barcode")
    search_fields = ("sku", "barcode", "name")
    ordering_fields = ("name", "unit_price", "created_at", "updated_at")

    def get_queryset(self):
        queryset = self._with_stock_quantity(super().get_queryset())
        queryset = self._filter_by_category(queryset)
        if self.request.query_params.get("is_active") == "true":
            if self._has_selective_list_filter():
                return queryset.filter(is_active=True)
            product_ids = self._get_active_product_ids()
            if product_ids is None:
                product_ids = list(
                    Product.objects.filter(is_active=True).values_list("id", flat=True)
                )
                self._set_active_product_ids(product_ids)
            return queryset.filter(id__in=product_ids)
        return queryset

    def _filter_by_category(self, queryset):
        category_ids = self._requested_category_ids()
        if not category_ids:
            return queryset
        category_ids = self._category_ids_with_descendants(category_ids)
        return queryset.filter(categories__id__in=category_ids).distinct()

    def _requested_category_ids(self):
        raw_values = []
        raw_values.extend(self.request.query_params.getlist("category"))
        raw_values.extend(self.request.query_params.getlist("categories"))
        category_ids = []
        for raw_value in raw_values:
            for value in raw_value.split(","):
                value = value.strip()
                if value.isdigit():
                    category_ids.append(int(value))
        return category_ids

    def _category_ids_with_descendants(self, category_ids):
        category_ids = set(category_ids)
        pending_ids = set(category_ids)
        while pending_ids:
            child_ids = set(
                ProductCategory.objects.filter(parent_id__in=pending_ids).values_list(
                    "id",
                    flat=True,
                )
            )
            pending_ids = child_ids - category_ids
            category_ids.update(child_ids)
        return category_ids

    def _with_stock_quantity(self, queryset):
        return queryset.annotate(
            stock_quantity_on_hand=Coalesce("stock__quantity_on_hand", Value(0)),
        )

    def _has_selective_list_filter(self):
        return bool(
            self.request.query_params.get("barcode")
            or self.request.query_params.get("search")
            or self.request.query_params.get("category")
            or self.request.query_params.get("categories")
        )

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
