from django.db.models import Count, Prefetch

from apps.attachments.models import Attachment

from .models import ProductCategory, ProductVariant, UnitOfMeasure
from .units import prime_base_units


def unit_usage_queryset():
    """``UnitOfMeasure`` rows carrying the ``product_count`` its serializer reads.

    ``UnitOfMeasureSerializer.get_product_count`` prefers an annotation and
    otherwise counts. The fallback runs once per *serialization*, not once per
    instance -- so a payload that nests ``unit_detail`` under every product (or
    every variant of one) pays a COUNT for each row even when the prefetched
    unit object is shared. Annotating here keeps the count one query for the
    whole page and leaves the serializer's arithmetic untouched.
    """
    return UnitOfMeasure.objects.annotate(
        product_count=Count("product_units", distinct=True),
    )


def unit_detail_prefetch(lookup):
    """Prefetch a nested ``unit_detail`` with its usage count already counted."""
    return Prefetch(lookup, queryset=unit_usage_queryset())


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


def category_detail_prefetch(lookup):
    """Prefetch ``category_details`` with the parent its ``parent_name`` reads.

    ``ProductCategorySerializer`` renders ``parent_name`` from ``parent.name``,
    so a bare string prefetch costs one query per *sub*category on the page —
    invisible in a shop whose categories are all top level, and one query per
    (product x category) pair in a shop that nests them. ``ProductCategoryViewSet``
    select_relates the parent for its own list; this is the same rule for every
    payload that embeds the serializer.
    """
    return Prefetch(
        lookup,
        queryset=ProductCategory.objects.select_related("parent"),
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
        unit_detail_prefetch("product__units__unit"),
        "product__units__barcodes",
        "option_values",
        "option_values__option",
        # product_detail (ProductCatalogSummarySerializer) serializes the parent
        # product's categories, variant options and modifier groups; prefetch
        # those chains so each doesn't fire once per variant.
        category_detail_prefetch("product__categories"),
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


# Marks an instance that came out of ``load_line_variants`` so a second,
# defensive preload of the same lines is a no-op instead of a repeat bulk load.
_LINE_PRELOADED_ATTR = "_pointy_line_preloaded"

# A bulk load costs a handful of queries however small the document is, so
# batching a *single* line is a regression: its two or three cold reads are
# cheaper than the load that would replace them. One-line sales are the
# commonest of all at a till, so both entry points share this threshold.
MIN_LINES_TO_PRELOAD = 2


def load_line_variants(variant_ids):
    """``{pk: variant}`` for ``variant_ids``, carrying every relation a document
    line's validation, pricing and discounting read.

    Document APIs resolve each line's variant with its own ``.get(pk=...)``
    (DRF ``PrimaryKeyRelatedField``), so the instances arrive bare: touching
    ``product.categories`` (discount eligibility), ``product.modifier_groups``
    (per-line modifier pricing), ``product.units`` (unit conversion) or
    ``variant.option_values`` (the display name) then costs a query each, per
    line. One bulk load turns all of that into a constant few queries.

    Both many-to-many relations are filtered in Python by their callers — a
    ``.filter()`` on the manager builds a fresh queryset and ignores this
    prefetch.
    """
    variant_ids = set(variant_ids)
    if not variant_ids:
        return {}
    enriched = (
        ProductVariant.objects.select_related("product")
        .prefetch_related(
            "option_values__option",
            "product__categories",
            "product__modifier_groups",
            "product__units__unit",
        )
        .in_bulk(variant_ids)
    )
    # The base unit is resolved once per line by ``resolve_unit``; prime it for
    # the whole cart in one query rather than one lookup per line.
    prime_base_units([variant.product for variant in enriched.values()])
    for variant in enriched.values():
        setattr(variant, _LINE_PRELOADED_ATTR, True)
    return enriched


def preload_line_variants(lines_data, *, key="variant"):
    """Swap the enriched instances from :func:`load_line_variants` into
    ``lines_data``.

    Lines validated through ``CheckoutLineSerializer`` arrive preloaded already
    — its list serializer loads them *before* the lines validate, the only point
    early enough for the per-line reads inside ``validate`` — so this is the
    safety net for entry points that hand over bare rows, and skips the load
    when every line is already enriched.
    """
    pending_ids = {
        line_data[key].pk
        for line_data in lines_data
        if not getattr(line_data[key], _LINE_PRELOADED_ATTR, False)
    }
    if len(pending_ids) < MIN_LINES_TO_PRELOAD:
        return
    enriched = load_line_variants(pending_ids)
    for line_data in lines_data:
        preloaded = enriched.get(line_data[key].pk)
        if preloaded is not None:
            line_data[key] = preloaded
