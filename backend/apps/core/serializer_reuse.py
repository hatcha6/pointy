"""Build a nested read serializer once per request and reuse it for every row.

``ModelSerializer.get_fields()`` re-introspects the model on *every*
construction — its concrete fields, its reverse relations, its
unique-together constraints — and builds a fresh ``Field`` object for each
column. A nested read serializer constructed inside ``to_representation``
therefore pays that introspection once per row rather than once per request.

The catalog list built roughly twelve nested serializers per product (each
variant, each unit, each attachment summary, each modifier group), which came
to 10,722 ``Field`` constructions and 604 ``get_fields()`` calls for a single
50-row page. Profiling ``product-list`` — the second most expensive endpoint
in the product, 2,956s of backend time in the 2026-09-16 field export — put
**52% of its wall time inside that field construction**, against 30ms of
actual database work.

Reuse is safe for *read* serialization because ``to_representation(instance)``
takes the instance as an argument and keeps no per-instance state. It is not
safe for writes (``is_valid``/``validated_data``/``errors`` all live on the
instance), so this helper is deliberately read-only.

Two rules for callers:

* Call :func:`render` (or ``to_representation`` on the instance
  :func:`reusable_serializer` hands back) — **never** ``.data``, which
  memoises ``_data`` on the serializer and would hand every subsequent row
  the first row's output.
* Keep ``extra_context`` to hashable flag values. It is part of the cache
  key, so two call sites that differ only by a flag (``catalog_list``,
  ``catalog_summary``) correctly get their own serializer.
"""

from __future__ import annotations

# Hung off the request-scoped serializer context, so the cache lives exactly
# as long as the request does. Namespaced because the context dict is shared
# with every serializer in the tree.
_CACHE_KEY = "_pointy_reusable_serializers"


def reusable_serializer(context, serializer_class, *, many=False, extra_context=None):
    """Return a read serializer of [serializer_class], reused within a request.

    [context] is the caller's serializer context — the per-request dict DRF
    threads through the tree, which is where the cache is kept. A caller with
    no dict context (a serializer instantiated bare, as tests do) simply gets
    a fresh serializer each time.
    """
    if not isinstance(context, dict):
        merged = dict(extra_context) if extra_context else {}
        return serializer_class(many=many, context=merged)

    try:
        key = (
            serializer_class,
            many,
            tuple(sorted(extra_context.items())) if extra_context else (),
        )
        hash(key)
    except TypeError:
        # An unhashable flag value: correctness first, build one for this row.
        merged = {**context, **(extra_context or {})}
        return serializer_class(many=many, context=merged)

    cache = context.get(_CACHE_KEY)
    if cache is None:
        cache = {}
        context[_CACHE_KEY] = cache

    serializer = cache.get(key)
    if serializer is None:
        merged = {**context, **extra_context} if extra_context else context
        serializer = serializer_class(many=many, context=merged)
        cache[key] = serializer
    return serializer


def render(context, serializer_class, instance, *, many=False, extra_context=None):
    """Serialize [instance] through a serializer reused across rows.

    The read-path replacement for ``SomeSerializer(instance, context=...).data``.
    """
    serializer = reusable_serializer(
        context,
        serializer_class,
        many=many,
        extra_context=extra_context,
    )
    return serializer.to_representation(instance)
