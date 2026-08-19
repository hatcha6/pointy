import django_filters
from django.conf import settings
from django.core.cache import cache
from decimal import Decimal, ROUND_HALF_UP

from django.db import transaction
from django.db.models import (
    BooleanField,
    Count,
    DecimalField,
    Exists,
    F,
    OuterRef,
    ProtectedError,
    Q,
    Sum,
    Value,
)
from django.db.models.functions import Coalesce
from django_filters.rest_framework import DjangoFilterBackend
from django.utils import timezone
from rest_framework import parsers, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.attachments.image_normalization import normalize_uploaded_image
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
from apps.core import caching
from apps.core.aggregates import related_count
from apps.core.permissions import HasPointyPermission
from .cache import attach_catalog_version, catalog_etag, catalog_version
from .identity import (
    BARCODE_FIELD,
    SKU_FIELD,
    find_barcode_conflict,
    find_sku_conflict,
)
from .models import (
    ModifierGroup,
    Product,
    ProductCategory,
    ProductVariant,
    UnitOfMeasure,
    VariantOption,
    VariantOptionValue,
)
from .serializers import (
    BoughtTogetherProductSerializer,
    ModifierGroupSerializer,
    ProductBulkArchiveSerializer,
    ProductBulkCategorizeSerializer,
    ProductBulkFlagsSerializer,
    ProductBulkRepriceSerializer,
    ProductCategorySerializer,
    ProductCatalogSerializer,
    ProductSetVariantPricesSerializer,
    ProductVariantSerializer,
    UnitOfMeasureSerializer,
    VariantOptionSerializer,
    VariantOptionValueSerializer,
)
from .search_filters import CatalogRelevanceFilter, VariantRelevanceFilter
from .services import (
    category_ids_with_descendants,
    image_attachment_prefetch,
    variant_detail_queryset,
)


def _within_upload_limit(uploaded_file) -> bool:
    """Whether reading the whole upload to normalize it is safe.

    An oversized file is left for store_uploaded_attachment to reject with the
    size error, rather than pulled into memory here just to re-encode it.
    """
    max_bytes = getattr(settings, "POINTY_ATTACHMENT_MAX_UPLOAD_BYTES", 0)
    return not max_bytes or getattr(uploaded_file, "size", 0) <= max_bytes


class ProductCategoryFilter(django_filters.FilterSet):
    root = django_filters.BooleanFilter(method="filter_root")

    class Meta:
        model = ProductCategory
        fields = ("is_active", "parent", "root", "is_quick_access")

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
    barcode = django_filters.CharFilter(method="filter_barcode")

    class Meta:
        model = ProductVariant
        fields = ("product", "is_active", "is_default", "sku")

    def filter_category(self, queryset, name, value):
        category_ids = requested_category_ids(self.request.query_params)
        if not category_ids:
            return queryset
        category_ids = category_ids_with_descendants(category_ids)
        return queryset.filter(
            product__categories__id__in=category_ids,
        ).distinct()

    def filter_barcode(self, queryset, name, value):
        # A scan may carry a *unit* barcode (the carton EAN): resolve it to the
        # product's variants too, so the POS/purchasing lookup lands on the
        # product and the client picks the matched unit from the payload.
        return queryset.filter(
            Q(barcode=value) | Q(product__units__barcodes__barcode=value)
        ).distinct()


class ConditionalListMixin:
    """304 Not Modified for catalog list polls.

    The ETag embeds the Redis catalog version (bumped by signals on any
    product/stock/image change — see cache.py), so an unchanged catalog answers
    a repeat poll before the queryset or serializer ever runs, and the LAN
    carries an empty body instead of the largest payload in the app. When the
    version is unavailable (Redis down, caching disabled) responses simply skip
    the ETag and clients fall back to plain 200s.
    """

    def list(self, request, *args, **kwargs):
        version = catalog_version()
        etag = catalog_etag(request, version)
        if etag is not None and request.headers.get("If-None-Match") == etag:
            response = Response(
                status=status.HTTP_304_NOT_MODIFIED, headers={"ETag": etag}
            )
            return attach_catalog_version(response, version)
        response = super().list(request, *args, **kwargs)
        if etag is not None and response.status_code == status.HTTP_200_OK:
            response["ETag"] = etag
            attach_catalog_version(response, version)
        return response


class ProductCategoryViewSet(ConditionalListMixin, viewsets.ModelViewSet):
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
    ordering_fields = ("display_order", "name", "created_at", "updated_at")

    def get_queryset(self):
        # select_related("parent"): the serializer renders parent_name from
        # parent.name, which is one query per subcategory on the page without it.
        #
        # The two counts used to be Count("children", distinct=True) and
        # Count("products", distinct=True) in the same annotate(). Both are
        # multi-valued relations, so a single query LEFT JOINs them together and
        # the database materialises every (child x product) pair per category.
        # distinct=True corrects the numbers but not the work. A subquery per
        # relation keeps each count an index scan on its own key, and counting
        # the categories M2M through-table directly is what the joined form did
        # anyway (it never reached catalog_product), so archived products keep
        # counting exactly as before.
        return (
            super()
            .get_queryset()
            .select_related("parent")
            .annotate(
                children_count=related_count(ProductCategory, "parent"),
                product_count=related_count(
                    Product.categories.through, "productcategory"
                ),
            )
            .order_by("display_order", "name", "id")
        )

    def perform_destroy(self, instance):
        # Subcategories use on_delete=PROTECT; turn the resulting ProtectedError
        # into a clean 400 instead of a 500 so the client can explain it.
        try:
            instance.delete()
        except ProtectedError:
            raise ValidationError(
                {
                    "detail": "Move or delete the subcategories before "
                    "deleting this category.",
                    "code": "has_children",
                }
            )


class ProductViewSet(ConditionalListMixin, viewsets.ModelViewSet):
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
        "bulk_archive": ("catalog.change_product", "catalog.delete_product"),
        "bulk_reprice": ("catalog.change_product",),
        "bulk_categorize": ("catalog.change_product",),
        "bulk_set_flags": ("catalog.change_product",),
        "set_variant_prices": ("catalog.change_product",),
        "image_search": ("catalog.view_product",),
        "image_import": ("catalog.change_product", "attachments.add_attachment"),
        "bought_together": ("catalog.view_product",),
    }
    queryset = Product.objects.prefetch_related(
        image_attachment_prefetch("attachments"),
        "categories",
        "units__unit",
        "units__barcodes",
        "variants",
        image_attachment_prefetch("variants__attachments"),
        "variants__option_values",
        "variants__option_values__option",
        # Each variant serializes its on-hand quantity (variant.stock is a 1:1);
        # prefetch it so quantity_on_hand doesn't query once per variant.
        "variants__stock",
        "variant_options",
        "variant_options__values",
        # Modifier groups are serialized for every product in the catalog list
        # twice: the modifier_groups id list (the M2M) and modifier_group_details
        # (link -> group -> options). Prefetch both chains so neither fires a
        # query per product (product_modifier_group_details reuses the links).
        "modifier_groups",
        "modifier_group_links__group__options",
    )
    filterset_fields = ("is_active",)
    # CatalogRelevanceFilter owns search + ordering for this viewset (it replaces
    # the stock SearchFilter/OrderingFilter): it ranks matches by relevance, keeps
    # numeric queries on codes, and emits a stable ORDER BY. DjangoFilterBackend
    # still handles ?is_active=. The fields it searches (variant sku/barcode, unit
    # barcode, variant/product name, aliases) live in that backend.
    filter_backends = (DjangoFilterBackend, CatalogRelevanceFilter)
    # Ordering values the client may request (mapped to stable orderings inside
    # CatalogRelevanceFilter). ``popularity`` is the "most bought" sort.
    ordering_fields = ("name", "created_at", "updated_at", "popularity")

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

    def get_serializer_context(self):
        context = super().get_serializer_context()
        # The catalog LIST rows drop the full image_attachments gallery (product
        # and nested variants) — the card shows only the primary image and the
        # detail screen re-fetches the rest. Retrieve keeps the full payload.
        if self.action == "list":
            context["catalog_summary"] = True
        return context

    def get_queryset(self):
        queryset = self._with_variant_rollups(super().get_queryset())
        queryset = self._filter_by_category(queryset)
        queryset = self._filter_by_barcode(queryset)
        queryset = self._filter_by_archived(queryset)
        queryset = self._filter_by_stock(queryset)
        queryset = self._filter_by_supplier(queryset)
        queryset = self._annotate_supplier_boost(queryset)
        # Default ("most bought" first) for any no-ordering API caller; the client
        # normally sends ?ordering= and CatalogRelevanceFilter finalises the sort.
        queryset = queryset.order_by("-popularity", "name", "id")
        if self.request.query_params.get("is_active") == "true":
            if self._has_selective_list_filter():
                return queryset.filter(
                    is_active=True,
                    variants__is_active=True,
                ).distinct()
            # Single-flight: a catalog write orphans this key for EVERY till at
            # once; without coalescing each till's next page re-runs the same
            # distinct id scan.
            product_ids = caching.get_or_compute_single_flight(
                self.active_cache_key,
                lambda: list(
                    Product.objects.filter(
                        is_active=True,
                        variants__is_active=True,
                        archived_at__isnull=True,
                    )
                    .distinct()
                    .values_list("id", flat=True)
                ),
                settings.POINTY_ACTIVE_PRODUCT_CACHE_TTL,
            )
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
        # Sellable = on-hand minus quotation-reserved (committed) units.
        return queryset.filter(
            Q(is_service=True)
            | Q(is_prepared=True)
            | Q(stock_quantity_on_hand__gt=F("stock_quantity_committed"))
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
        # Unit (carton/box) barcodes resolve to their product too.
        return queryset.filter(
            Q(variants__barcode=barcode) | Q(units__barcodes__barcode=barcode)
        ).distinct()

    def _filter_by_supplier(self, queryset):
        # "Products from supplier X" is resolved through that supplier's purchase
        # orders: any product whose variant appears on a (non-cancelled) purchase
        # line of a PO placed with the supplier. Lets the inventory list show the
        # catalogue a given supplier actually stocks. Resolved via a PurchaseLine
        # subquery (rather than chaining filter+exclude across the multi-valued
        # variants relation, which would wrongly drop products that also have a
        # cancelled PO). Lazy import keeps catalog/purchasing free of an import
        # cycle (purchasing already imports catalog models).
        supplier_id = self.request.query_params.get("supplier")
        if not supplier_id:
            return queryset
        from apps.purchasing.models import PurchaseLine

        supplied_product_ids = (
            PurchaseLine.objects.filter(purchase_order__supplier_id=supplier_id)
            .exclude(purchase_order__status="cancelled")
            .values_list("variant__product_id", flat=True)
        )
        return queryset.filter(id__in=supplied_product_ids)

    def _annotate_supplier_boost(self, queryset):
        # Soft supplier boost for the purchasing PO catalog: ?preferred_supplier=<id>
        # does NOT filter (unlike ?supplier=) — it floats that supplier's products to
        # the top while keeping everything else searchable, so a buyer can still add a
        # product the supplier hasn't stocked before. Applied in the ORDER BY by
        # CatalogRelevanceFilter. Always annotate (a constant False when no supplier)
        # so the annotation is present whenever the filter wants to order by it. The
        # Exists() is a scalar subquery — zero extra queries, no join fan-out.
        supplier_id = self.request.query_params.get("preferred_supplier")
        if not supplier_id or not str(supplier_id).isdigit():
            return queryset.annotate(
                is_supplier_product=Value(False, output_field=BooleanField())
            )
        from apps.purchasing.models import PurchaseLine

        supplied = (
            PurchaseLine.objects.filter(
                purchase_order__supplier_id=supplier_id,
                variant__product_id=OuterRef("pk"),
            )
            .exclude(purchase_order__status="cancelled")
        )
        return queryset.annotate(is_supplier_product=Exists(supplied))

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
            stock_quantity_committed=Coalesce(
                Sum("variants__stock__quantity_committed"),
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
            or self.request.query_params.get("supplier")
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

    @action(detail=True, methods=["get"], url_path="bought-together")
    def bought_together(self, request, pk=None):
        """Products most often sold in the same paid order as this one.

        A shop-wide "frequently bought together" insight (same co-occurrence
        ranking the AI assistant uses) surfaced on the product detail page.
        """
        from apps.sales.cooccurrence import products_bought_together
        from apps.sales.models import Order

        product = self.get_object()
        try:
            limit = int(request.query_params.get("limit", 8))
        except (TypeError, ValueError):
            limit = 8
        limit = max(1, min(limit, 20))

        ranked = products_bought_together(
            orders=Order.objects.filter(status=Order.Status.PAID),
            product=product,
            limit=limit,
        )
        products_by_id = {
            product.id: product
            for product in Product.objects.filter(
                id__in=[product_id for product_id, _ in ranked]
            ).prefetch_related("attachments", "variants")
        }
        entries = [
            {"product": products_by_id[product_id], "orders_together": orders_together}
            for product_id, orders_together in ranked
            if product_id in products_by_id
        ]
        serializer = BoughtTogetherProductSerializer(
            entries,
            many=True,
            context=self.get_serializer_context(),
        )
        return Response({"product": product.id, "results": serializer.data})

    def _create_attachment_for_product(self, request, product):
        data = request.data.copy()
        data.setdefault("role", Attachment.Role.PRODUCT_IMAGE)
        data.setdefault(
            "is_primary",
            not product.attachments.active()
            .filter(role=Attachment.Role.PRODUCT_IMAGE)
            .exists(),
        )
        # Decode the bytes and re-encode anything the clients cannot render, so a
        # HEIC/AVIF/TIFF picked from disk -- which the picker mislabels as
        # image/jpeg -- can never be stored under a false type and show up as an
        # invisible tile. Undecodable payloads are refused rather than stored as
        # a broken product photo. Oversized files fall through to
        # store_uploaded_attachment, which reports the size error instead.
        upload = data.get("file")
        if upload is not None and _within_upload_limit(upload):
            normalized = normalize_uploaded_image(upload)
            if normalized is None:
                raise ValidationError(
                    {"file": "Uploaded file is not an image we can display."}
                )
            data["file"] = normalized
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

    @action(detail=False, methods=["post"], url_path="bulk-archive")
    def bulk_archive(self, request):
        serializer = ProductBulkArchiveSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        ids = serializer.validated_data["ids"]
        archived = serializer.validated_data["archived"]

        updated = 0
        with transaction.atomic():
            products = Product.objects.select_for_update().filter(pk__in=ids)
            for product in products:
                if archived and not product.is_archived:
                    product.archive(by=request.user)
                    updated += 1
                elif not archived and product.is_archived:
                    product.restore()
                    updated += 1
        self._clear_catalog_cache()
        return Response({"updated": updated})

    @action(detail=False, methods=["post"], url_path="bulk-reprice")
    def bulk_reprice(self, request):
        serializer = ProductBulkRepriceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        ids = serializer.validated_data["ids"]
        mode = serializer.validated_data["mode"]
        value = serializer.validated_data["value"]

        now = timezone.now()
        changed = []
        with transaction.atomic():
            # Reprice the default (sellable) variant of each selected product.
            variants = ProductVariant.objects.select_for_update().filter(
                product_id__in=ids,
                is_default=True,
            )
            for variant in variants:
                new_price = self._reprice_value(variant.unit_price, mode, value)
                if new_price != variant.unit_price:
                    variant.unit_price = new_price
                    variant.updated_at = now
                    changed.append(variant)
            if changed:
                ProductVariant.objects.bulk_update(
                    changed, ["unit_price", "updated_at"]
                )
        self._clear_catalog_cache()
        return Response({"updated": len(changed)})

    @staticmethod
    def _reprice_value(current, mode, value):
        current = Decimal(current)
        if mode == "set":
            result = value
        elif mode == "increase_percent":
            result = current * (Decimal("1") + value / Decimal("100"))
        elif mode == "decrease_percent":
            result = current * (Decimal("1") - value / Decimal("100"))
        elif mode == "increase_amount":
            result = current + value
        elif mode == "decrease_amount":
            result = current - value
        else:
            result = current
        result = result.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        return result if result > 0 else Decimal("0.00")

    @action(detail=False, methods=["post"], url_path="bulk-categorize")
    def bulk_categorize(self, request):
        serializer = ProductBulkCategorizeSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        ids = serializer.validated_data["ids"]
        mode = serializer.validated_data["mode"]
        categories = list(
            ProductCategory.objects.filter(
                pk__in=serializer.validated_data["category_ids"]
            )
        )

        updated = 0
        with transaction.atomic():
            products = Product.objects.select_for_update().filter(pk__in=ids)
            for product in products:
                if mode == "replace":
                    product.categories.set(categories)
                elif mode == "add":
                    product.categories.add(*categories)
                else:  # remove
                    product.categories.remove(*categories)
                updated += 1
        self._clear_catalog_cache()
        return Response({"updated": updated})

    @action(detail=False, methods=["post"], url_path="bulk-set-flags")
    def bulk_set_flags(self, request):
        serializer = ProductBulkFlagsSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        ids = serializer.validated_data["ids"]
        flags = {
            field: serializer.validated_data[field]
            for field in ProductBulkFlagsSerializer.FLAG_FIELDS
            if field in serializer.validated_data
        }

        with transaction.atomic():
            updated = (
                Product.objects.filter(pk__in=ids)
                .update(updated_at=timezone.now(), **flags)
            )
        self._clear_catalog_cache()
        return Response({"updated": updated})

    @action(detail=True, methods=["post"], url_path="set-variant-prices")
    def set_variant_prices(self, request, pk=None):
        """Set explicit selling prices for this product's variants in one go.

        Backs the product-details "Change prices" dialog: validates every
        variant belongs to this product, then writes all prices atomically so a
        partial failure can't leave the product half-repriced.
        """
        product = self.get_object()
        serializer = ProductSetVariantPricesSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        entries = serializer.validated_data["prices"]

        valid_ids = set(
            product.variants.values_list("id", flat=True)
        )
        prices_by_variant = {}
        for entry in entries:
            variant_id = entry["variant"]
            if variant_id not in valid_ids:
                raise ValidationError(
                    {"prices": f"Variant {variant_id} does not belong to this product."}
                )
            prices_by_variant[variant_id] = entry["unit_price"]

        now = timezone.now()
        changed = []
        with transaction.atomic():
            variants = ProductVariant.objects.select_for_update().filter(
                product=product,
                id__in=prices_by_variant.keys(),
            )
            for variant in variants:
                new_price = prices_by_variant[variant.id]
                if new_price != variant.unit_price:
                    variant.unit_price = new_price
                    variant.updated_at = now
                    changed.append(variant)
            if changed:
                ProductVariant.objects.bulk_update(changed, ["unit_price", "updated_at"])
        self._clear_catalog_cache()
        product.refresh_from_db()
        serializer = self.get_serializer(product)
        return Response(serializer.data)

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


def _int_param(request, name):
    raw = request.query_params.get(name)
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


class ProductVariantViewSet(ConditionalListMixin, viewsets.ModelViewSet):
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
        # Read-only "is this code taken" probe behind the same view permission.
        "identity_check": ("catalog.view_productvariant",),
    }
    # The prefetch shape lives with the serializer (catalog.services) because the
    # stock-count reconciliation screen embeds the same serializer.
    queryset = variant_detail_queryset()
    # Same relevance search as the POS catalog: VariantRelevanceFilter replaces
    # the stock SearchFilter/OrderingFilter so purchasing and the stock-count
    # item picker get ranked, trigram-accelerated results instead of a plain
    # ILIKE OR. DjangoFilterBackend still applies ProductVariantFilter params.
    filter_backends = (DjangoFilterBackend, VariantRelevanceFilter)
    filterset_class = ProductVariantFilter
    # Consumed by VariantRelevanceFilter now (kept for reference / discoverability).
    search_fields = ("sku", "barcode", "name", "product__name")
    ordering_fields = ("product__name", "name", "sku", "unit_price", "created_at")

    def get_queryset(self):
        # Variants of archived products never appear in the purchasing picker
        # (or anywhere this endpoint feeds).
        return super().get_queryset().filter(product__archived_at__isnull=True)

    @action(detail=False, methods=["get"], url_path="identity-check")
    def identity_check(self, request):
        """Is this SKU / barcode still free?

        Lets the product and variant forms answer "that barcode belongs to
        <product>" while the user is still typing, instead of after a failed
        save. Deliberately queries the unfiltered model rather than
        get_queryset(): a code held by an *archived* product is still taken, and
        a form that called it free would fail at the unique index.
        """
        exclude_ids = [
            value
            for value in [_int_param(request, "exclude_variant")]
            if value is not None
        ]
        sku = request.query_params.get(SKU_FIELD, "")
        barcode = request.query_params.get(BARCODE_FIELD, "")
        sku_conflict = find_sku_conflict(sku, exclude_variant_ids=exclude_ids)
        barcode_conflict = find_barcode_conflict(barcode, exclude_variant_ids=exclude_ids)
        return Response(
            {
                SKU_FIELD: None if sku_conflict is None else sku_conflict.as_payload(),
                BARCODE_FIELD: (
                    None if barcode_conflict is None else barcode_conflict.as_payload()
                ),
            }
        )

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


class ModifierGroupViewSet(ConditionalListMixin, viewsets.ModelViewSet):
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


class UnitOfMeasureViewSet(ConditionalListMixin, viewsets.ModelViewSet):
    """The global, editable unit registry. Seeded (``is_system``) units can be
    deactivated or relabelled but never deleted, and their ``code`` is locked so
    existing products keep resolving."""

    serializer_class = UnitOfMeasureSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_unitofmeasure",),
        "retrieve": ("catalog.view_unitofmeasure",),
        "create": ("catalog.add_unitofmeasure",),
        "update": ("catalog.change_unitofmeasure",),
        "partial_update": ("catalog.change_unitofmeasure",),
        "destroy": ("catalog.delete_unitofmeasure",),
    }
    queryset = UnitOfMeasure.objects.annotate(
        product_count=Count("product_units", distinct=True),
    ).order_by("display_order", "name", "id")
    filterset_fields = ("is_active", "dimension", "is_system")
    search_fields = ("code", "name", "abbreviation")
    ordering_fields = ("display_order", "name", "dimension", "created_at")

    def perform_update(self, serializer):
        instance = serializer.instance
        if instance is not None and instance.is_system:
            new_code = serializer.validated_data.get("code")
            if new_code and new_code != instance.code:
                raise ValidationError(
                    {"code": "The code of a built-in unit cannot be changed."}
                )
        serializer.save()

    def perform_destroy(self, instance):
        if instance.is_system:
            raise ValidationError("Built-in units cannot be deleted; deactivate instead.")
        if instance.product_units.exists():
            raise ValidationError("This unit is in use by products and cannot be deleted.")
        super().perform_destroy(instance)
