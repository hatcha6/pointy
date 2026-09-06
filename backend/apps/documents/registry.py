"""The closed registry of document types.

A model is a document only because it is registered here, and registration
requires declaring the *whole* contract: what a draft may touch, what submitting
posts, what cancelling reverses, which fields survive a submit, what blocks a
cancellation, who may perform each transition, and how a correction is made.

Every clause is mandatory. There is no default that lets a type quietly skip one
— ``DocumentType`` is a dataclass with no defaults, so a missing clause is a
``TypeError`` at import time rather than an untested cancel path discovered by a
customer. That is the direct answer to ERPNext's ~100 submittable DocTypes,
many of which have cancel paths nobody has ever run.
"""

from __future__ import annotations

import dataclasses
from datetime import timedelta
from typing import Callable, Mapping, Sequence

from apps.documents.statuses import (
    HOUSEKEEPING_FIELDS,
    LIFECYCLE_FIELDS,
    Correction,
    Transition,
)


@dataclasses.dataclass(frozen=True)
class DocumentType:
    #: Stable machine key. Appears in the trail and in API payloads, so it is
    #: part of the contract with the client and does not change.
    key: str
    #: Arabic name, used where the shop reads it — stock-movement notes, the
    #: document trail, printed corrections.
    label: str
    model: type
    #: The column carrying the document's own number, or ``None`` for documents
    #: that never had one (a payment is identified by what it settles).
    number_field: str | None
    #: The column that says when this document's money moved. Must agree with
    #: ``apps.core.money_dates`` when the model is registered there — the two
    #: are checked against each other so a second definition cannot drift in.
    money_date_field: str | None
    #: Whether this document is ever a draft. Some are not: a payment, an
    #: expense, a receipt — money either moved or it did not, and there is no
    #: half-written state to be in. Those are born submitted, stamped on insert
    #: by ``DocumentMixin.save`` rather than by every caller remembering to.
    has_draft_state: bool
    #: Reversible, unvalued positions a draft is allowed to hold (stock
    #: reservations, commitments, expected quantities). A draft may never write
    #: to the stock ledger, the money position or a receivable.
    draft_effects: Sequence[str]
    #: What submitting posts. Documentation for humans and a checklist for the
    #: round-trip test, which asserts cancelling puts every one of them back.
    submit_effects: Sequence[str]
    corrections: Sequence[Correction]
    #: Fields that may still change after submit, because they carry no
    #: financial consequence. Everything else is frozen.
    mutable_after_submit: Sequence[str]
    #: Columns the primitive maintains itself: derived progress, caches. Not
    #: frozen, because they are not what the document *says*.
    derived_fields: Sequence[str]
    #: Related accessors that must be empty before this document can be
    #: cancelled, as ``(accessor, Arabic label)`` pairs.
    blocks_cancel: Sequence[tuple[str, str]]
    #: Related accessors holding documents that are cancelled *with* this one,
    #: innermost first.
    cascades: Sequence[str]
    #: ``(document) -> None`` recomputing the derived progress field. One
    #: function, called from one place, so it cannot drift (ERPNext's
    #: ``set_status`` is called from a dozen and reliably does).
    progress: Callable | None
    permissions: Mapping[str, str]
    #: How long the person who created a document may retract it themselves.
    #: ``None`` means never — only a permission holder can.
    correction_window: timedelta | None
    #: ``(document, *, at, actor, reason, context) -> None``. Posts
    #: counter-entries, never deletes. Always dated ``at`` (the moment of
    #: cancellation), never backdated into the original period. ``context``
    #: carries whatever the domain needs and the primitive has no opinion
    #: about — the till a refund is paid out of, for instance.
    reverse: Callable
    #: ``(document, *, actor) -> document`` producing the successor draft.
    #: Required when ``AMEND`` is offered.
    amend_copy: Callable | None
    #: ``(document) -> bool``: whether this submitted document may still be
    #: rewritten in place. Required when ``IN_PLACE`` is offered.
    in_place_allowed: Callable | None
    #: ``(document, *, actor, reason) -> None`` releasing the reversible
    #: positions a draft was holding — a stock reservation, a commitment, an
    #: expected quantity. Required when ``draft_effects`` is non-empty.
    release_draft: Callable | None

    @property
    def model_label(self) -> str:
        return self.model._meta.label

    def number_of(self, document) -> str:
        if not self.number_field:
            return f"{self.model._meta.verbose_name} #{document.pk}"
        return getattr(document, self.number_field, "") or f"#{document.pk}"

    def offers(self, correction: Correction) -> bool:
        return correction in self.corrections


_BY_KEY: dict[str, DocumentType] = {}
_BY_MODEL: dict[type, DocumentType] = {}
_FROZEN_FIELDS: dict[str, frozenset[str]] = {}


class RegistrationError(RuntimeError):
    """A document type was declared with a clause that cannot be honoured."""


def register(**clauses) -> DocumentType:
    doc_type = DocumentType(**clauses)
    _validate(doc_type)
    if doc_type.key in _BY_KEY:
        raise RegistrationError(f"Duplicate document type key {doc_type.key!r}.")
    if doc_type.model in _BY_MODEL:
        raise RegistrationError(
            f"{doc_type.model_label} is already registered as "
            f"{_BY_MODEL[doc_type.model].key!r}."
        )
    _BY_KEY[doc_type.key] = doc_type
    _BY_MODEL[doc_type.model] = doc_type
    return doc_type


def _validate(doc_type: DocumentType) -> None:
    from apps.core import money_dates
    from apps.documents.models import DocumentMixin

    model = doc_type.model
    if not issubclass(model, DocumentMixin):
        raise RegistrationError(
            f"{model.__name__} must inherit DocumentMixin to be a document."
        )

    concrete = {field.name for field in model._meta.get_fields() if hasattr(field, "attname")}
    for clause, names in (
        ("number_field", [doc_type.number_field] if doc_type.number_field else []),
        ("money_date_field", [doc_type.money_date_field] if doc_type.money_date_field else []),
        ("mutable_after_submit", list(doc_type.mutable_after_submit)),
        ("derived_fields", list(doc_type.derived_fields)),
    ):
        for name in names:
            if name not in concrete:
                raise RegistrationError(
                    f"{doc_type.key}.{clause} names {name!r}, which "
                    f"{model.__name__} does not have."
                )

    declared = money_dates.MONEY_DATE_FIELDS.get(model._meta.label)
    if declared and declared != doc_type.money_date_field:
        # One definition per money figure. If these two ever disagree, a report
        # and a period lock are slicing the same document by different days.
        raise RegistrationError(
            f"{doc_type.key} dates its money by {doc_type.money_date_field!r} but "
            f"apps.core.money_dates says {declared!r}."
        )

    accessors = {
        field.get_accessor_name()
        for field in model._meta.get_fields()
        if field.is_relation and field.auto_created and not field.concrete
    }
    for accessor, _label in doc_type.blocks_cancel:
        if accessor not in accessors:
            raise RegistrationError(
                f"{doc_type.key}.blocks_cancel names {accessor!r}, which is not a "
                f"reverse relation on {model.__name__}."
            )
    for accessor in doc_type.cascades:
        if accessor not in accessors:
            raise RegistrationError(
                f"{doc_type.key}.cascades names {accessor!r}, which is not a "
                f"reverse relation on {model.__name__}."
            )

    if Correction.AMEND in doc_type.corrections and doc_type.amend_copy is None:
        raise RegistrationError(
            f"{doc_type.key} offers AMEND but declares no amend_copy."
        )
    if Correction.IN_PLACE in doc_type.corrections and doc_type.in_place_allowed is None:
        raise RegistrationError(
            f"{doc_type.key} offers IN_PLACE but declares no in_place_allowed "
            f"predicate, so nothing would ever close the document to rewrites."
        )
    if not doc_type.has_draft_state and (
        doc_type.draft_effects or doc_type.release_draft is not None
    ):
        raise RegistrationError(
            f"{doc_type.key} is born submitted, so it cannot hold draft effects "
            f"or declare a way to release them."
        )
    if doc_type.draft_effects and doc_type.release_draft is None:
        raise RegistrationError(
            f"{doc_type.key} lets a draft hold {tuple(doc_type.draft_effects)} but "
            f"declares no release_draft to give them back."
        )
    if not callable(doc_type.reverse):
        raise RegistrationError(f"{doc_type.key}.reverse is not callable.")
    if doc_type.progress is not None and not callable(doc_type.progress):
        raise RegistrationError(f"{doc_type.key}.progress is not callable.")

    required = {Transition.SUBMIT, Transition.CANCEL}
    # A correction route with no permission behind it is a route anyone can
    # take, which is how ERPNext ends up handing cancel to the whole shop.
    if Correction.AMEND in doc_type.corrections:
        required.add(Transition.AMEND)
    if Correction.ALLOW_AFTER_SUBMIT in doc_type.corrections:
        required.add(Transition.EDIT)
    if Correction.IN_PLACE in doc_type.corrections:
        required.add(Transition.CORRECT)
    for transition in sorted(required):
        if transition not in doc_type.permissions:
            raise RegistrationError(
                f"{doc_type.key} offers {transition} but declares no permission "
                f"for it."
            )


def frozen_fields(doc_type: DocumentType) -> frozenset[str]:
    """Everything a submitted document may not change.

    Computed by subtraction rather than declaration: a field added to a model
    later is frozen by default, which is the safe direction. Opting a field out
    is a deliberate line in ``mutable_after_submit``.
    """
    cached = _FROZEN_FIELDS.get(doc_type.key)
    if cached is not None:
        return cached
    names: set[str] = set()
    for field in doc_type.model._meta.concrete_fields:
        if field.name in LIFECYCLE_FIELDS or field.attname in LIFECYCLE_FIELDS:
            continue
        if field.name in HOUSEKEEPING_FIELDS:
            continue
        if field.name in doc_type.mutable_after_submit:
            continue
        if field.name in doc_type.derived_fields:
            continue
        names.add(field.name)
        names.add(field.attname)
    frozen = frozenset(names)
    _FROZEN_FIELDS[doc_type.key] = frozen
    return frozen


def _unregister(key: str) -> None:
    """Remove a registration. Tests only — the registry is closed by design."""
    doc_type = _BY_KEY.pop(key, None)
    if doc_type is not None:
        _BY_MODEL.pop(doc_type.model, None)
        _FROZEN_FIELDS.pop(key, None)


def for_model(model) -> DocumentType | None:
    return _BY_MODEL.get(model)


def for_instance(instance) -> DocumentType | None:
    return _BY_MODEL.get(type(instance))


def by_key(key: str) -> DocumentType | None:
    return _BY_KEY.get(key)


def all_types() -> tuple[DocumentType, ...]:
    return tuple(_BY_KEY.values())


__all__ = [
    "DocumentType",
    "RegistrationError",
    "all_types",
    "by_key",
    "for_instance",
    "for_model",
    "frozen_fields",
    "register",
]
