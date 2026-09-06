"""Who may move a document, and when.

Two rules, both of which ERPNext gets wrong for a shop.

**Permission.** In ERPNext whoever can submit can cancel. At a counter that is
exactly backwards: a cashier submits a hundred sales a day and must not be able
to unwind yesterday's. Every transition therefore carries its own permission
code, declared by the document type.

**Window.** A cashier who mis-rings a sale needs to fix it in the next thirty
seconds without finding a manager. The window *widens* who may act, never
narrows it: inside it the person who submitted the document may retract it
themselves; outside it, only a permission holder can. This generalises the
cashier window in ``apps.sales.services.validate_order_adjustment_allowed``,
which is already the right policy written once for one table.
"""

from __future__ import annotations

from django.utils import timezone

from apps.core.period_lock import assert_period_open
from apps.documents.errors import TransitionNotPermitted
from apps.documents.statuses import Transition


def resolve_actor(actor=None, request=None):
    if actor is not None:
        return actor
    user = getattr(request, "user", None)
    if user is not None and getattr(user, "is_authenticated", False):
        return user
    return None


def within_window(doc_type, document, actor, *, now=None) -> bool:
    if doc_type.correction_window is None or actor is None:
        return False
    submitted_at = document.submitted_at or document.created_at
    if submitted_at is None:
        return False
    author_id = document.submitted_by_id or getattr(document, "created_by_id", None)
    if author_id is None or author_id != actor.pk:
        return False
    now = now or timezone.now()
    return (now - submitted_at) <= doc_type.correction_window


def assert_permitted(doc_type, transition, *, document, actor=None, request=None):
    """Refuse a transition this user may not perform.

    A caller with no user at all — a management command, the importer, the
    business simulation — passes through. That is the same rule the rest of the
    backend already applies: these guards exist to govern people.
    """
    actor = resolve_actor(actor, request)
    if actor is None or getattr(actor, "is_superuser", False):
        return
    for code in _codes(doc_type.permissions.get(transition)):
        if actor.has_perm(code):
            return
    if transition in (Transition.CANCEL, Transition.EDIT) and within_window(
        doc_type, document, actor
    ):
        return
    raise TransitionNotPermitted(
        f"You do not have permission to {transition} "
        f"{doc_type.number_of(document)}."
    )


def _codes(declared):
    """A transition may name several codes, any one of which authorises it.

    Not laxity: it is how a *flow* can carry its own narrower permission. The
    POS cash purchase submits and receives a purchase order on the cashier's
    behalf, deliberately without handing that cashier the manual lifecycle
    permissions — the endpoint's own permission map is the real gate, and this
    is the primitive agreeing rather than second-guessing it.
    """
    if not declared:
        return ()
    if isinstance(declared, str):
        return (declared,)
    return tuple(declared)


def document_money_date(doc_type, document):
    if not doc_type.money_date_field:
        return None
    return getattr(document, doc_type.money_date_field, None)


def assert_period_open_for_cancel(doc_type, document, *, at, actor=None):
    """Check the lock against **both** dates a cancellation touches.

    The reversal itself is dated ``at`` — today — and never backdated, so it can
    never rewrite a closed month's ledger. But the retraction also changes what
    the *original* period reports, because every report filters a document by
    its own money date and reads its status: void a September sale in October
    and September's revenue moves, whatever the reversal is dated.

    So the original period is checked too. In practice that is the check that
    bites, and it is the one ``void_order`` never had — the very scenario
    ``apps.core.period_lock`` opens its own docstring with.
    """
    number = doc_type.number_of(document)
    original = document_money_date(doc_type, document)
    if original is not None:
        assert_period_open(
            original,
            user=actor,
            entity_type=doc_type.key,
            entity_id=document.pk,
            action=f"cancel {number}",
        )
    assert_period_open(
        at,
        user=actor,
        entity_type=doc_type.key,
        entity_id=document.pk,
        action=f"reverse {number}",
    )


def assert_period_open_for_submit(doc_type, document, *, at, actor=None):
    assert_period_open(
        money_dates_value(doc_type, document, at),
        user=actor,
        entity_type=doc_type.key,
        entity_id=document.pk,
        action=f"submit {doc_type.number_of(document)}",
    )


def money_dates_value(doc_type, document, fallback):
    value = document_money_date(doc_type, document)
    return value if value is not None else fallback


__all__ = [
    "assert_period_open_for_cancel",
    "assert_period_open_for_submit",
    "assert_permitted",
    "document_money_date",
    "resolve_actor",
    "within_window",
]
