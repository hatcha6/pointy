from .models import ProductCategory


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
