import django_filters
from django.core.cache import cache
from decimal import Decimal

from django.db.models import DecimalField, Count, Q, Sum, Value
from django.db.models.functions import Coalesce
from rest_framework import parsers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.attachments.image_search import (
    ProductImageDownloadError,
    ProductImageImportError,
    ProductImageSearchError,
    ProductImageSearchUnavailable,
    import_product_image_from_token,
    search_product_images,
)
from apps.attachments.models import Attachment
from apps.attachments.serializers import (
    AttachmentSerializer,
    AttachmentSummarySerializer,
    ProductImageImportSerializer,
    ProductImageSearchQuerySerializer,
    ProductImageSearchResultSerializer,
)
from apps.core.permissions import HasPointyPermission
from .models import (
    ModifierGroup,
    Product,
    ProductCategory,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
)
from .serializers import (
    ModifierGroupSerializer,
    ProductCategorySerializer,
    ProductCatalogSerializer,
    ProductVariantSerializer,
    VariantOptionSerializer,
    VariantOptionValueSerializer,
)
from .services import category_ids_with_descendants


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
        "archive": ("catalog.delete_product",),
        "restore": ("catalog.change_product",),
        "image_search": ("catalog.view_product",),
        "image_import": ("catalog.change_product", "attachments.add_attachment"),
    }
    queryset = Product.objects.prefetch_related(
        "attachments",
        "categories",
        "variants",
        "variants__attachments",
        "variants__option_values",
        "variants__option_values__option",
        "variant_options",
        "variant_options__values",
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
        if self.action == "attachments":
            if request.method == "POST":
                return ("catalog.change_product", "attachments.add_attachment")
            return ("catalog.view_product", "attachments.view_attachment")
        if self.action == "image_search":
            return ("catalog.view_product",)
        if self.action == "image_import":
            return ("catalog.change_product", "attachments.add_attachment")
        return self.permission_map.get(self.action)

    def get_queryset(self):
        queryset = self._with_variant_rollups(super().get_queryset())
        queryset = self._filter_by_category(queryset)
        queryset = self._filter_by_barcode(queryset)
        queryset = self._filter_by_archived(queryset)
        queryset = self._filter_by_stock(queryset)
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
                        archived_at__isnull=True,
                    )
                    .distinct()
                    .values_list("id", flat=True)
                )
                self._set_active_product_ids(product_ids)
            return queryset.filter(id__in=product_ids)
        return queryset

    def _filter_by_archived(self, queryset):
        # Archived products are hidden from the catalog list (and therefore POS
        # and search) by default. The dedicated "Archived" view passes
        # ?archived=true; ?archived=all opts out of the filter entirely. Only
        # the list action is scoped — detail/retrieve/restore must still reach
        # archived rows.
        if self.action != "list":
            return queryset
        archived = self.request.query_params.get("archived")
        if archived == "all":
            return queryset
        if archived in ("true", "1", "only"):
            return queryset.filter(archived_at__isnull=False)
        return queryset.filter(archived_at__isnull=True)

    def _filter_by_stock(self, queryset):
        # POS passes ?in_stock=true when overselling is disabled so cashiers
        # never see (or accidentally sell) products that are out of stock.
        # Service products (labor/fees) and made-to-order (prepared) dishes
        # carry no stock of their own — the checkout stock guard skips them too
        # (see apps.sales.services.prepare_sale_stock_adjustments) — so they
        # always remain visible regardless of their rolled-up quantity.
        if self.request.query_params.get("in_stock") != "true":
            return queryset
        return queryset.filter(
            Q(is_service=True)
            | Q(is_prepared=True)
            | Q(stock_quantity_on_hand__gt=0)
        )

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
                Value(Decimal("0")),
                output_field=DecimalField(max_digits=12, decimal_places=3),
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

    @action(detail=True, methods=["get", "post"], url_path="variants")
    def variants(self, request, pk=None):
        product = self.get_object()
        if request.method.lower() == "post":
            return self._create_variant_for_product(request, product)

        queryset = (
            product.variants.select_related("product")
            .prefetch_related(
                "attachments",
                "product__attachments",
                "option_values",
                "option_values__option",
            )
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

    @action(
        detail=True,
        methods=["get", "post"],
        url_path="attachments",
        parser_classes=[parsers.MultiPartParser, parsers.FormParser, parsers.JSONParser],
    )
    def attachments(self, request, pk=None):
        product = self.get_object()
        if request.method.lower() == "post":
            return self._create_attachment_for_product(request, product)

        queryset = product.attachments.active().select_related(
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

    @action(detail=False, methods=["get"], url_path="image-search")
    def image_search(self, request):
        serializer = ProductImageSearchQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        try:
            results = search_product_images(
                query=serializer.validated_data["q"],
                page=serializer.validated_data["page"],
                page_size=serializer.validated_data["page_size"],
            )
        except ProductImageSearchUnavailable as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
        except ProductImageSearchError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_502_BAD_GATEWAY)

        return Response(
            {
                "results": ProductImageSearchResultSerializer(
                    results,
                    many=True,
                    context=self.get_serializer_context(),
                ).data,
            }
        )

    @action(detail=True, methods=["post"], url_path="image-import")
    def image_import(self, request, pk=None):
        product = self.get_object()
        serializer = ProductImageImportSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            attachment = import_product_image_from_token(
                owner=product,
                import_token=serializer.validated_data["import_token"],
                is_primary=serializer.validated_data["is_primary"],
                created_by=request.user if request.user.is_authenticated else None,
            )
        except ProductImageDownloadError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_502_BAD_GATEWAY)
        except ProductImageImportError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)

        self._clear_catalog_cache()
        return Response(
            AttachmentSummarySerializer(
                attachment,
                context=self.get_serializer_context(),
            ).data,
            status=status.HTTP_201_CREATED,
        )

    def _create_attachment_for_product(self, request, product):
        data = request.data.copy()
        data.setdefault("role", Attachment.Role.PRODUCT_IMAGE)
        data.setdefault(
            "is_primary",
            not product.attachments.active()
            .filter(role=Attachment.Role.PRODUCT_IMAGE)
            .exists(),
        )
        serializer = AttachmentSerializer(
            data=data,
            context={**self.get_serializer_context(), "owner": product},
        )
        serializer.is_valid(raise_exception=True)
        attachment = serializer.save()
        self._clear_catalog_cache()
        return Response(
            AttachmentSummarySerializer(
                attachment,
                context=self.get_serializer_context(),
            ).data,
            status=status.HTTP_201_CREATED,
        )

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

    @action(detail=True, methods=["post"])
    def archive(self, request, pk=None):
        product = self.get_object()
        product.archive(by=request.user)
        self._clear_catalog_cache()
        return Response(self.get_serializer(product).data)

    @action(detail=True, methods=["post"])
    def restore(self, request, pk=None):
        product = self.get_object()
        product.restore()
        self._clear_catalog_cache()
        return Response(self.get_serializer(product).data)

    def perform_destroy(self, instance):
        # Soft-delete: archive instead of removing the row so sales/purchase
        # history (PurchaseLine.variant is on_delete=PROTECT) is preserved and
        # the product stays restorable.
        instance.archive(by=self.request.user)
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
        "attachments",
        "product__attachments",
        "option_values",
        "option_values__option",
    )
    filterset_class = ProductVariantFilter
    search_fields = ("sku", "barcode", "name", "product__name")
    ordering_fields = ("product__name", "name", "sku", "unit_price", "created_at")

    def get_queryset(self):
        # Variants of archived products never appear in the purchasing picker
        # (or anywhere this endpoint feeds).
        return super().get_queryset().filter(product__archived_at__isnull=True)

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


class ModifierGroupViewSet(viewsets.ModelViewSet):
    serializer_class = ModifierGroupSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_modifiergroup",),
        "retrieve": ("catalog.view_modifiergroup",),
        "create": ("catalog.add_modifiergroup",),
        "update": ("catalog.change_modifiergroup",),
        "partial_update": ("catalog.change_modifiergroup",),
        "destroy": ("catalog.delete_modifiergroup",),
    }
    queryset = ModifierGroup.objects.prefetch_related("options")
    filterset_fields = ("is_active",)
    search_fields = ("name",)
    ordering_fields = ("display_order", "name", "created_at")
