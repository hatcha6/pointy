"""Aggregate helpers that keep list endpoints linear in their row count.

The one thing here is :func:`related_count`. Annotating two multi-valued
relations in a single ``annotate()`` makes the database LEFT JOIN both and
materialise their *cross product* per parent row. ``distinct=True`` corrects
the returned number but not the work, and the GROUP BY runs over the whole
table before pagination can trim it — so the cost grows as
``relation_a x relation_b`` while the query *count* stays identical, which is
why only a query plan can catch it.
"""

from django.db.models import Count, IntegerField, OuterRef, Subquery
from django.db.models.functions import Coalesce


def related_count(model, field):
    """Count a parent's rows in ``model`` as an independent subquery.

    ``field`` is the name of ``model``'s foreign key back to the parent being
    annotated. Giving each relation its own subquery keeps every count an index
    scan on that key, so rows scanned stay linear in the page size no matter how
    many rows hang off each parent.

    The explicit ``order_by()`` drops the model's ``Meta.ordering`` from the
    grouped subquery — which matters beyond tidiness, because ordering that
    traverses a relation leaves its JOIN behind in the subquery even though
    Django omits the ORDER BY itself. ``Coalesce`` reproduces the 0 the LEFT
    JOIN used to produce for a parent with no related rows.
    """
    return Coalesce(
        Subquery(
            model.objects.filter(**{field: OuterRef("pk")})
            .order_by()
            .values(field)
            .annotate(related_count=Count("pk"))
            .values("related_count")[:1],
            output_field=IntegerField(),
        ),
        0,
    )
