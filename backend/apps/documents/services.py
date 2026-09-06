"""The transitions. Every document in the system moves through these functions
and nowhere else: ``submit``, ``cancel``, ``amend``, ``supersede``,
``edit_submitted`` and ``correct_in_place``.

What each one owns: locking the row, checking the state it starts from, checking
the permission and the window, checking the period lock, calling the type's own
side-effect hooks, flipping the status, recomputing the derived progress, and
writing the trail. What none of them owns: *what* the side effects are. That
stays with the domain, declared in the registry, because only purchasing knows
what unwinding a delivery means.
"""

from __future__ import annotations

from django.db import transaction
from django.utils import timezone

from apps.documents import policy, registry, trail
from apps.documents.errors import (
    CorrectionNotOffered,
    DocumentBlocked,
    DocumentFrozen,
    InvalidTransition,
)
from apps.documents.guards import system_write
from apps.documents.models import DocumentEvent
from apps.documents.statuses import Correction, DocumentStatus, Transition

#: How many blocking rows a refusal names before it stops listing them. The
#: caller gets a count either way; this only bounds the message.
_BLOCKER_SAMPLE = 5


class UnregisteredDocument(TypeError):
    """The model is not a document. Registering it is a deliberate act."""


def _type_for(document):
    doc_type = registry.for_instance(document)
    if doc_type is None:
        raise UnregisteredDocument(
            f"{type(document).__name__} is not registered in apps.documents.registry."
        )
    return doc_type


def _lock(doc_type, document):
    # ``_base_manager``: a transition must be able to reach a document whose
    # model's default manager filters — an archived one, a soft-deleted one —
    # because those are exactly the rows someone needs to retract.
    return doc_type.model._base_manager.select_for_update().get(pk=document.pk)


def _refresh_progress(doc_type, document) -> None:
    if doc_type.progress is not None:
        doc_type.progress(document)


def blocking_documents(document, *, doc_type=None):
    """The rows that stand between this document and its cancellation.

    Computed from the real foreign keys rather than from a link table, because
    the foreign keys are already there and a second copy of the graph is a
    second thing that can be wrong. ERPNext scans every DocType with a Link
    field and reports the *type* that blocks; this reports the rows, so the user
    can be shown what to undo.
    """
    doc_type = doc_type or _type_for(document)
    blockers = []
    for accessor, label in doc_type.blocks_cancel:
        related = getattr(document, accessor)
        queryset = related.all()
        if "doc_status" in {f.name for f in related.model._meta.concrete_fields}:
            queryset = queryset.exclude(doc_status=DocumentStatus.CANCELLED)
        # One more than the sample: a short read has counted itself, and only a
        # full one needs the second query. This runs on every cancel, once per
        # declared blocker, and the overwhelmingly common answer is "none" or
        # "one".
        rows = list(queryset[: _BLOCKER_SAMPLE + 1])
        if not rows:
            continue
        blockers.append(
            {
                "accessor": accessor,
                "label": label,
                "count": (
                    len(rows)
                    if len(rows) <= _BLOCKER_SAMPLE
                    else queryset.count()
                ),
                "ids": [row.pk for row in rows[:_BLOCKER_SAMPLE]],
            }
        )
    return blockers


@transaction.atomic
def submit(document, *, actor=None, request=None, at=None, reason=""):
    doc_type = _type_for(document)
    locked = _lock(doc_type, document)
    if locked.doc_status != DocumentStatus.DRAFT:
        raise InvalidTransition(
            transition=Transition.SUBMIT,
            from_status=locked.doc_status,
            number=doc_type.number_of(locked),
        )
    actor = policy.resolve_actor(actor, request)
    policy.assert_permitted(doc_type, Transition.SUBMIT, document=locked, actor=actor)
    at = at or timezone.now()
    policy.assert_period_open_for_submit(doc_type, locked, at=at, actor=actor)

    locked.doc_status = DocumentStatus.SUBMITTED
    locked.submitted_at = at
    locked.submitted_by = actor
    locked.save(update_fields=["doc_status", "submitted_at", "submitted_by", "updated_at"])
    _refresh_progress(doc_type, locked)
    trail.record(
        locked,
        DocumentEvent.Action.SUBMITTED,
        doc_type=doc_type,
        actor=actor,
        reason=reason,
    )
    return locked


@transaction.atomic
def cancel(
    document,
    *,
    reason,
    actor=None,
    request=None,
    at=None,
    context=None,
    _cascade=False,
):
    """Retract a document and put back what it did.

    A draft is retracted by giving back the reversible positions it was holding
    (a reservation, an expected quantity) — there is nothing valued to reverse.
    A submitted document is reversed: its cascades first, innermost outwards,
    then its own counter-entries, always dated now.

    ``context`` is whatever the domain needs and the primitive has no opinion
    about — which till is doing this, which drawer the refund comes out of. A
    refund leaves the shift that hands the money over, not the shift that took
    it, and that is knowledge only the caller has.
    """
    doc_type = _type_for(document)
    locked = _lock(doc_type, document)
    if locked.doc_status == DocumentStatus.CANCELLED:
        raise InvalidTransition(
            transition=Transition.CANCEL,
            from_status=locked.doc_status,
            number=doc_type.number_of(locked),
        )
    actor = policy.resolve_actor(actor, request)
    was_submitted = locked.doc_status == DocumentStatus.SUBMITTED
    # Throwing away a draft and reversing a posted document are different acts;
    # a type may say so by declaring a permission for each.
    transition = (
        Transition.CANCEL
        if was_submitted or Transition.DISCARD not in doc_type.permissions
        else Transition.DISCARD
    )
    policy.assert_permitted(doc_type, transition, document=locked, actor=actor)

    at = at or timezone.now()
    if was_submitted:
        blockers = blocking_documents(locked, doc_type=doc_type)
        if blockers:
            raise DocumentBlocked(
                number=doc_type.number_of(locked), blockers=blockers
            )
        policy.assert_period_open_for_cancel(doc_type, locked, at=at, actor=actor)
        for accessor in doc_type.cascades:
            children = getattr(locked, accessor).all()
            child_model_fields = {
                field.name for field in children.model._meta.concrete_fields
            }
            if "doc_status" in child_model_fields:
                children = children.exclude(doc_status=DocumentStatus.CANCELLED)
            for child in list(children):
                cancel(
                    child,
                    reason=reason,
                    actor=actor,
                    at=at,
                    context=context,
                    _cascade=True,
                )
        doc_type.reverse(
            locked, at=at, actor=actor, reason=reason, context=context or {}
        )
    elif doc_type.release_draft is not None:
        doc_type.release_draft(locked, actor=actor, reason=reason)

    locked.doc_status = DocumentStatus.CANCELLED
    locked.cancelled_at = at
    locked.cancelled_by = actor
    locked.cancel_reason = reason or ""
    locked.save(
        update_fields=[
            "doc_status",
            "cancelled_at",
            "cancelled_by",
            "cancel_reason",
            "updated_at",
        ]
    )
    _refresh_progress(doc_type, locked)
    trail.record(
        locked,
        DocumentEvent.Action.CANCELLED,
        doc_type=doc_type,
        actor=actor,
        reason=reason,
        details={"reversed": was_submitted, "cascaded": bool(_cascade)},
    )
    return locked


@transaction.atomic
def amend(document, *, actor=None, request=None, reason="", at=None):
    """Retract a document and open its successor, in one action.

    ERPNext makes this two: cancel, then amend from the cancelled document.
    That extra step is why its users hold the cancel permission more widely than
    they should, and it is not load-bearing — a cancellation that exists only to
    be immediately amended is a worse audit record, not a better one. Here it is
    one call in one transaction, and the trail says ``amended`` rather than
    leaving a bare cancellation for someone to interpret later.
    """
    doc_type = _type_for(document)
    if not doc_type.offers(Correction.AMEND):
        raise CorrectionNotOffered(
            correction=Correction.AMEND,
            model_label=doc_type.model_label,
            offered=[str(item) for item in doc_type.corrections],
        )
    actor = policy.resolve_actor(actor, request)
    locked = _lock(doc_type, document)
    if locked.doc_status == DocumentStatus.SUBMITTED:
        locked = cancel(locked, reason=reason, actor=actor, at=at)
    elif locked.doc_status == DocumentStatus.DRAFT:
        raise InvalidTransition(
            transition=Transition.AMEND,
            from_status=locked.doc_status,
            number=doc_type.number_of(locked),
        )
    if locked.superseded_by_id is not None:
        raise InvalidTransition(
            transition=Transition.AMEND,
            from_status="superseded",
            number=doc_type.number_of(locked),
        )
    policy.assert_permitted(doc_type, Transition.AMEND, document=locked, actor=actor)

    successor = doc_type.amend_copy(locked, actor=actor)
    successor.doc_status = DocumentStatus.DRAFT
    successor.amended_from = locked
    successor.amendment_index = locked.amendment_index + 1
    successor.save()
    _link_successor(doc_type, locked, successor)

    trail.record(
        locked,
        DocumentEvent.Action.AMENDED,
        doc_type=doc_type,
        actor=actor,
        reason=reason,
        details={"successor_id": successor.pk, "amendment_index": successor.amendment_index},
    )
    trail.record(
        successor,
        DocumentEvent.Action.CREATED,
        doc_type=doc_type,
        actor=actor,
        reason=reason,
        details={"amended_from_id": locked.pk},
    )
    return successor


@transaction.atomic
def supersede(
    document, successor, *, reason, actor=None, request=None, at=None, context=None
):
    """Retire a document in favour of a different one that replaces it.

    Not an amendment: the successor is its own document with its own number —
    an accepted quotation becoming a sale, an intake plan becoming a purchase
    order. The forward pointer is the same field either way, so "what replaced
    this?" has one answer regardless of which route was taken.
    """
    doc_type = _type_for(document)
    actor = policy.resolve_actor(actor, request)
    locked = cancel(
        document, reason=reason, actor=actor, request=request, at=at, context=context
    )
    _link_successor(doc_type, locked, successor)
    trail.record(
        locked,
        DocumentEvent.Action.SUPERSEDED,
        doc_type=doc_type,
        actor=actor,
        reason=reason,
        details={"successor_id": successor.pk},
    )
    return locked


def _link_successor(doc_type, document, successor) -> None:
    document.superseded_by = successor
    document.save(update_fields=["superseded_by", "updated_at"])


@transaction.atomic
def edit_submitted(document, *, changes, actor=None, request=None, reason=""):
    """Change a field that carries no financial consequence, in place.

    The route ERPNext has but never names, which is why its users cancel a whole
    invoice to fix a reference number. Only fields the type listed in
    ``mutable_after_submit`` may be touched, and the before/after lands in the
    trail.
    """
    doc_type = _type_for(document)
    if not doc_type.offers(Correction.ALLOW_AFTER_SUBMIT):
        raise CorrectionNotOffered(
            correction=Correction.ALLOW_AFTER_SUBMIT,
            model_label=doc_type.model_label,
            offered=[str(item) for item in doc_type.corrections],
        )
    allowed = set(doc_type.mutable_after_submit)
    refused = sorted(set(changes) - allowed)
    if refused:
        raise DocumentFrozen(
            model_label=doc_type.model_label,
            number=doc_type.number_of(document),
            fields=refused,
        )
    locked = _lock(doc_type, document)
    if locked.doc_status != DocumentStatus.SUBMITTED:
        raise InvalidTransition(
            transition=Transition.EDIT,
            from_status=locked.doc_status,
            number=doc_type.number_of(locked),
        )
    actor = policy.resolve_actor(actor, request)
    policy.assert_permitted(doc_type, Transition.EDIT, document=locked, actor=actor)

    diff = {}
    for field, value in changes.items():
        before = getattr(locked, field)
        if before == value:
            continue
        diff[field] = {"from": _plain(before), "to": _plain(value)}
        setattr(locked, field, value)
    if not diff:
        return locked
    locked.save(update_fields=[*diff.keys(), "updated_at"])
    trail.record(
        locked,
        DocumentEvent.Action.EDITED,
        doc_type=doc_type,
        actor=actor,
        reason=reason,
        details={"changes": diff},
    )
    return locked


@transaction.atomic
def correct_in_place(document, *, mutate, reason, actor=None, request=None):
    """Rewrite a submitted document while its type still allows it.

    This is the one route ERPNext does not have, and the one place this design
    knowingly trades audit fidelity for a shopkeeper's ability to fix their own
    mistake. A purchase order stays correctable until money settles against it,
    because an owner who typed the wrong cost must not have to cancel a
    delivery to fix a digit.

    What makes it a route rather than a hole: the condition is declared by the
    type and checked here, the permission and the period lock are checked here,
    and the before/after of every frozen field the mutation touched is written
    to the trail. Today's code rewrites the same rows and records only that
    *something* changed.

    ``mutate`` is a callable taking the locked document and doing the domain's
    own work. It runs with the freeze lifted, because rewriting the document is
    the point; everything around it is what keeps that honest.
    """
    doc_type = _type_for(document)
    if not doc_type.offers(Correction.IN_PLACE):
        raise CorrectionNotOffered(
            correction=Correction.IN_PLACE,
            model_label=doc_type.model_label,
            offered=[str(item) for item in doc_type.corrections],
        )
    locked = _lock(doc_type, document)
    if locked.doc_status != DocumentStatus.SUBMITTED:
        raise InvalidTransition(
            transition=Transition.CORRECT,
            from_status=locked.doc_status,
            number=doc_type.number_of(locked),
        )
    actor = policy.resolve_actor(actor, request)
    policy.assert_permitted(doc_type, Transition.CORRECT, document=locked, actor=actor)
    if not doc_type.in_place_allowed(locked):
        blockers = blocking_documents(locked, doc_type=doc_type)
        raise DocumentBlocked(number=doc_type.number_of(locked), blockers=blockers)
    policy.assert_period_open_for_cancel(
        doc_type, locked, at=timezone.now(), actor=actor
    )

    before = _snapshot(doc_type, locked)
    with system_write():
        result = mutate(locked)
    subject = result if result is not None else locked
    subject.refresh_from_db()
    diff = _diff(before, _snapshot(doc_type, subject))
    trail.record(
        subject,
        DocumentEvent.Action.CORRECTED,
        doc_type=doc_type,
        actor=actor,
        reason=reason,
        details={"changes": diff},
    )
    return subject


def _snapshot(doc_type, document):
    fields = sorted(
        field.attname
        for field in doc_type.model._meta.concrete_fields
        if field.name in registry.frozen_fields(doc_type)
    )
    row = (
        doc_type.model._base_manager.filter(pk=document.pk).values(*fields).first()
    )
    return row or {}


def _diff(before, after):
    changed = {}
    for field, was in before.items():
        now = after.get(field)
        if was != now:
            changed[field] = {"from": _plain(was), "to": _plain(now)}
    return changed


def _plain(value):
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return str(value)


__all__ = [
    "UnregisteredDocument",
    "amend",
    "correct_in_place",
    "blocking_documents",
    "cancel",
    "edit_submitted",
    "submit",
    "supersede",
]
