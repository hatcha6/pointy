import django_filters
from django.core.cache import cache
from django.db.models import Count, Sum, Value
from django.db.models.functions import Coalesce
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission
from .models import (
    Product,
    ProductCategory,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
)
from .serializers import (
    ProductCategorySerializer,
    ProductCatalogSerializer,
    ProductVariantSerializer,
    VariantOptionSerializer,
    VariantOptionValueSerializer,
)


class ProductCategoryFilter(django_filters.FilterSet):
    root = django_filters.BooleanFilter(method="filter_root")

    class Meta:
        model = ProductCategory
        fields = ("is_active", "parent", "root")

    def filter_root(self, queryset, name, value):
        return queryset.filter(parent__isnull=bool(value))


def requested_category_ids(query_params):
    raw_values = []
    raw_values.extend(query_params.getlist("category"))
    raw_values.extend(query_params.getlist("categories"))
    category_ids = []
    for raw_value in raw_values:
        for value in raw_value.split(","):
            value = value.strip()
            if value.isdigit():
                category_ids.append(int(value))
    return category_ids


def category_ids_with_descendants(category_ids):
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


class ProductVariantFilter(django_filters.FilterSet):
    category = django_filters.CharFilter(method="filter_category")
    categories = django_filters.CharFilter(method="filter_category")

    class Meta:
        model = ProductVariant
        fields = ("product", "is_active", "is_default", "barcode", "sku")

    def filter_category(self, queryset, name, value):
        category_ids = requested_category_ids(self.request.query_params)
        if not category_ids:
            return queryset
        category_ids = category_ids_with_descendants(category_ids)
        return queryset.filter(
            product__categories__id__in=category_ids,
        ).distinct()


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
    filterset_class = ProductCategoryFilter
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
    serializer_class = ProductCatalogSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_product",),
        "retrieve": ("catalog.view_product",),
        "create": ("catalog.add_product",),
        "update": ("catalog.change_product",),
        "partial_update": ("catalog.change_product",),
        "destroy": ("catalog.delete_product",),
    }
    queryset = Product.objects.prefetch_related(
        "categories",
        "variants",
        "variants__option_values",
        "variants__option_values__option",
        "variant_options",
    )
    filterset_fields = ("is_active",)
    search_fields = (
        "variants__sku",
        "variants__barcode",
        "variants__name",
        "name",
    )
    ordering_fields = ("name", "created_at", "updated_at")

    def get_required_permissions(self, request):
        if self.action == "variants":
            if request.method == "POST":
                return ("catalog.add_productvariant",)
            return ("catalog.view_productvariant",)
        return self.permission_map.get(self.action)

    def get_queryset(self):
        queryset = self._with_variant_rollups(super().get_queryset())
        queryset = self._filter_by_category(queryset)
        queryset = self._filter_by_barcode(queryset)
        queryset = queryset.order_by("name", "id")
        if self.request.query_params.get("is_active") == "true":
            if self._has_selective_list_filter():
                return queryset.filter(
                    is_active=True,
                    variants__is_active=True,
                ).distinct()
            product_ids = self._get_active_product_ids()
            if product_ids is None:
                product_ids = list(
                    Product.objects.filter(
                        is_active=True,
                        variants__is_active=True,
                    )
                    .distinct()
                    .values_list("id", flat=True)
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

    def _filter_by_barcode(self, queryset):
        barcode = self.request.query_params.get("barcode")
        if not barcode:
            return queryset
        return queryset.filter(variants__barcode=barcode).distinct()

    def _requested_category_ids(self):
        return requested_category_ids(self.request.query_params)

    def _category_ids_with_descendants(self, category_ids):
        return category_ids_with_descendants(category_ids)

    def _with_variant_rollups(self, queryset):
        return queryset.annotate(
            stock_quantity_on_hand=Coalesce(
                Sum("variants__stock__quantity_on_hand"),
                Value(0),
            ),
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

    @action(detail=True, methods=["get", "post"], url_path="variants")
    def variants(self, request, pk=None):
        product = self.get_object()
        if request.method.lower() == "post":
            return self._create_variant_for_product(request, product)

        queryset = (
            product.variants.select_related("product")
            .prefetch_related("option_values", "option_values__option")
            .order_by("-is_default", "name", "id")
        )
        page = self.paginate_queryset(queryset)
        if page is not None:
            serializer = ProductVariantSerializer(
                page,
                many=True,
                context=self.get_serializer_context(),
            )
            return self.get_paginated_response(serializer.data)
        serializer = ProductVariantSerializer(
            queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        return Response(serializer.data)

    def _create_variant_for_product(self, request, product):
        payload_product = request.data.get("product")
        if payload_product is not None and str(payload_product) != str(product.pk):
            return Response(
                {"product": "Variant does not belong to the selected product."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        serializer = ProductVariantSerializer(
            data={**request.data, "product": product.pk},
            context={**self.get_serializer_context(), "product": product},
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        self._clear_catalog_cache()
        return Response(serializer.data, status=status.HTTP_201_CREATED)

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


class ProductVariantViewSet(viewsets.ModelViewSet):
    product_cache_key = ProductViewSet.active_cache_key
    serializer_class = ProductVariantSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_productvariant",),
        "retrieve": ("catalog.view_productvariant",),
        "create": ("catalog.add_productvariant",),
        "update": ("catalog.change_productvariant",),
        "partial_update": ("catalog.change_productvariant",),
        "destroy": ("catalog.delete_productvariant",),
    }
    queryset = ProductVariant.objects.select_related("product").prefetch_related(
        "option_values",
        "option_values__option",
    )
    filterset_class = ProductVariantFilter
    search_fields = ("sku", "barcode", "name", "product__name")
    ordering_fields = ("product__name", "name", "sku", "unit_price", "created_at")

    def perform_create(self, serializer):
        variant = serializer.save()
        self._clear_product_cache()
        return variant

    def perform_update(self, serializer):
        variant = serializer.save()
        self._clear_product_cache()
        return variant

    def perform_destroy(self, instance):
        super().perform_destroy(instance)
        self._clear_product_cache()

    def _clear_product_cache(self):
        try:
            cache.delete(self.product_cache_key)
        except Exception:
            pass


class VariantOptionViewSet(viewsets.ModelViewSet):
    serializer_class = VariantOptionSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_variantoption",),
        "retrieve": ("catalog.view_variantoption",),
        "create": ("catalog.add_variantoption",),
        "update": ("catalog.change_variantoption",),
        "partial_update": ("catalog.change_variantoption",),
        "destroy": ("catalog.delete_variantoption",),
    }
    queryset = VariantOption.objects.prefetch_related("values")
    filterset_fields = ("is_active",)
    search_fields = ("code", "name")
    ordering_fields = ("display_order", "name", "created_at")


class VariantOptionValueViewSet(viewsets.ModelViewSet):
    serializer_class = VariantOptionValueSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_variantoptionvalue",),
        "retrieve": ("catalog.view_variantoptionvalue",),
        "create": ("catalog.add_variantoptionvalue",),
        "update": ("catalog.change_variantoptionvalue",),
        "partial_update": ("catalog.change_variantoptionvalue",),
        "destroy": ("catalog.delete_variantoptionvalue",),
    }
    queryset = VariantOptionValue.objects.select_related("option")
    filterset_fields = ("option", "is_active")
    search_fields = ("code", "name", "option__name")
    ordering_fields = ("option__display_order", "display_order", "name", "created_at")
