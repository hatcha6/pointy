from .models import ProductCategory, ProductVariant


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
