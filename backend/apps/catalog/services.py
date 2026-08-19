from django.db.models import Prefetch

from apps.attachments.models import Attachment

from .models import ProductCategory, ProductVariant


def image_attachment_prefetch(lookup):
    """Prefetch product/variant image attachments with their serialized FKs.

    AttachmentSummarySerializer reads storage_volume.name, created_by.username
    and owner_content_type (via owner_type). A bare string prefetch leaves those
    FKs unfetched, so every image on a catalog page fired three extra queries —
    the dominant catalog-list N+1 (~three quarters of product-list's queries).
    select_related pulls them in with the prefetch; the default ordering is
    unchanged, so owner_attachments still picks the primary image the same way.
    """
    return Prefetch(
        lookup,
        queryset=Attachment.objects.select_related(
            "owner_content_type",
            "storage_volume",
            "created_by",
        ),
    )


def variant_detail_queryset():
    """Every relation ``ProductVariantSerializer`` reads, in one queryset.

    The prefetch shape belongs to the *serializer*, not to one viewset: any
    endpoint that embeds this serializer pays 15 queries per row without it
    (the parent product tree, the image attachments' own FKs, the 1:1 stock
    row behind ``quantity_on_hand``). Callers that nest it under a document
    line use it as ``Prefetch("variant", queryset=variant_detail_queryset())``
    so a new serializer field can never be fast in one endpoint and an N+1 in
    another.
    """
    return ProductVariant.objects.select_related(
        "product",
        # quantity_on_hand reads the 1:1 stock row; without this it queried
        # inventory once per variant.
        "stock",
    ).prefetch_related(
        image_attachment_prefetch("attachments"),
        image_attachment_prefetch("product__attachments"),
        "product__units__unit",
        "product__units__barcodes",
        "option_values",
        "option_values__option",
        # product_detail (ProductCatalogSummarySerializer) serializes the parent
        # product's categories, variant options and modifier groups; prefetch
        # those chains so each doesn't fire once per variant.
        Prefetch(
            "product__categories",
            queryset=ProductCategory.objects.select_related("parent"),
        ),
        "product__variant_options__values",
        "product__modifier_group_links__group__options",
    )


def category_ids_with_descendants(category_ids):
    """Expand a set of category ids to include all descendant categories.

    Shared by the catalog variant endpoints and the inventory stock-count
    scope so a category-scoped query always covers nested categories.
    """
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


def preload_line_variants(lines_data, *, key="variant"):
    """Load every line's variant once with the relations the callers read per
    line, then swap the enriched instances into ``lines_data``.

    Document APIs resolve each line's variant with its own ``.get(pk=...)``
    (DRF ``PrimaryKeyRelatedField``), so the instances arrive bare: touching
    ``variant.product`` (a query), ``product.categories`` (discount
    eligibility) and ``variant.option_values`` (the display name) then costs a
    query each, per line. One bulk load with those relations preloaded turns
    3 queries/line into 3 for the whole request.
    """
    variant_ids = {line_data[key].pk for line_data in lines_data}
    if not variant_ids:
        return
    enriched = (
        ProductVariant.objects.select_related("product")
        .prefetch_related("option_values__option", "product__categories")
        .in_bulk(variant_ids)
    )
    for line_data in lines_data:
        preloaded = enriched.get(line_data[key].pk)
        if preloaded is not None:
            line_data[key] = preloaded
