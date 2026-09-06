"""Where the freeze bites.

ERPNext enforces immutability in exactly one Python method, and then routes
around it constantly with ``db_set`` and raw SQL, so the guarantee is real in
principle and porous in practice. We enforce it in the two places a Django
application can actually write a row — ``Model.save()`` and
``QuerySet.update()`` — and provide exactly one escape hatch, which is
greppable and enumerated by a test.

The escape exists because some writes to submitted documents are legitimate and
are not user actions: ``repost_valuation`` restamping a sold line's cost, a data
migration, a backup restore, the business simulation. This follows the doctrine
``apps.core.period_lock`` already sets down for the period lock — *the guard
governs people, not code*. It is also why there is no database trigger here: a
trigger would block the repost and the restore too, and the house keeps one
enforcement layer you can read rather than two that disagree.
"""

from __future__ import annotations

import threading
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation

from apps.documents import registry
from apps.documents.errors import DocumentFrozen
from apps.documents.statuses import DocumentStatus

_state = threading.local()


def is_system_write() -> bool:
    return getattr(_state, "depth", 0) > 0


@contextmanager
def system_write():
    """Lift the freeze for a machine path that legitimately rewrites history.

    Reentrant. Every call site is expected to be justified in review and is
    counted by ``apps.documents.test_guards``; if that count grows without a
    reason, the guarantee is being eroded one import at a time.
    """
    _state.depth = getattr(_state, "depth", 0) + 1
    try:
        yield
    finally:
        _state.depth -= 1


def _differs(current, stored) -> bool:
    if current is None or stored is None:
        return current is not stored
    if isinstance(stored, Decimal) and not isinstance(current, Decimal):
        try:
            current = Decimal(str(current))
        except (InvalidOperation, ValueError):
            return True
    if isinstance(current, Decimal) and isinstance(stored, Decimal):
        return current.compare(stored) != 0
    return current != stored


def _touched_frozen_names(doc_type, update_fields) -> tuple[str, ...]:
    frozen = registry.frozen_fields(doc_type)
    if update_fields is None:
        return tuple(
            field.name
            for field in doc_type.model._meta.concrete_fields
            if field.name in frozen
        )
    return tuple(name for name in update_fields if name in frozen)


def assert_not_frozen(instance, update_fields=None) -> None:
    """Refuse a save that would change what a submitted document says.

    Cheap in the common case: a save naming ``update_fields`` that touches no
    frozen column never reads the database at all, which is what keeps this off
    the checkout path's critical section.
    """
    if is_system_write() or instance.pk is None:
        return
    doc_type = registry.for_instance(instance)
    if doc_type is None:
        return
    candidates = _touched_frozen_names(doc_type, update_fields)
    if not candidates:
        return

    model = doc_type.model
    # ``update_fields`` may name a relation either way round ("customer" or
    # "customer_id") — Django accepts both, so a guard that only understood one
    # of them would wave the other straight through.
    attnames = {
        field.name: field.attname
        for field in model._meta.concrete_fields
        if field.name in candidates or field.attname in candidates
    }
    stored = (
        model._base_manager.filter(pk=instance.pk)
        .values("doc_status", *attnames.values())
        .first()
    )
    if stored is None or stored["doc_status"] == DocumentStatus.DRAFT:
        return

    changed = [
        name
        for name, attname in attnames.items()
        if _differs(getattr(instance, attname), stored[attname])
    ]
    if changed:
        raise DocumentFrozen(
            model_label=doc_type.model_label,
            number=doc_type.number_of(instance),
            fields=sorted(changed),
        )


def is_live(document) -> bool:
    """Whether this document still counts.

    The Python-side companion to ``DocumentQuerySet.live()``, for the loops that
    sum a prefetched relation rather than asking the database again.
    """
    return getattr(document, "doc_status", None) != DocumentStatus.CANCELLED


class DocumentQuerySetMixin:
    """Makes ``.update()`` respect the freeze, and offers ``.live()``.

    ``QuerySet.update()`` never calls ``save()``, so without this the whole
    guarantee is one ``.filter(...).update(total=0)`` away from being fiction.
    """

    def live(self):
        """Everything that still counts: retracted documents drop out.

        Types whose reversal is a *counter document* (a payment's opposing row,
        a sale's return) do not need this — their sums net out on their own.
        It is for the ones whose retraction simply stops them counting, where a
        cancelled row left in a total is the same bug as a deleted row missing
        from one.
        """
        return self.exclude(doc_status=DocumentStatus.CANCELLED)

    def with_lifecycle_relations(self):
        """Load what the lifecycle fields serialize, in a fixed query count.

        ``cancelled_by`` is the one relation ``DocumentLifecycleFields``
        traverses, and it costs a query *per cancelled row* when it is not
        loaded — invisible on a page of live documents and linear on a page of
        retracted ones, which is the shape a bug takes when it only appears
        after something goes wrong. ``superseded_by`` needs no join: it goes
        out as an id.
        """
        return self.select_related("cancelled_by")

    def update(self, **kwargs):
        doc_type = registry.for_model(self.model)
        if doc_type is not None and not is_system_write():
            frozen = registry.frozen_fields(doc_type)
            touched = sorted(name for name in kwargs if name in frozen)
            if touched:
                blocked = (
                    self.exclude(doc_status=DocumentStatus.DRAFT)
                    .order_by()
                    .values_list("pk", flat=True)[:1]
                )
                first = list(blocked)
                if first:
                    instance = self.model._base_manager.get(pk=first[0])
                    raise DocumentFrozen(
                        model_label=doc_type.model_label,
                        number=doc_type.number_of(instance),
                        fields=touched,
                    )
        return super().update(**kwargs)


__all__ = [
    "DocumentQuerySetMixin",
    "assert_not_frozen",
    "is_live",
    "is_system_write",
    "system_write",
]
