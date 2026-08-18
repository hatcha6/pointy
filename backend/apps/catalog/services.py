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


def product_catalog_prefetches():
    """Every relation ProductCatalogSerializer touches, for a Product queryset.

    Kept in one place because the serializer is embedded well outside the
    catalog app (the inventory stock and stock-movement lists render it as
    ``product_detail``); a caller that misses one of these pays a query per row
    for it. Measured on stock-movement-list: 23 queries/row without this list,
    0 with it.
    """
    return [
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
    ]


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
