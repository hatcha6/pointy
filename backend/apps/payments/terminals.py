"""The shop's card machines: which ones it owns, and which bank each feeds.

Two questions, one list. The first — *is this slip from one of our terminals?* —
is the trust check that has existed since card receipts were scannable. The
second is new: *which of our bank accounts did that machine settle into?* They
have to be answered from the same rows, because a shop that adds a terminal in
one place and maps it in another will eventually have a terminal in only one of
them, and the money will land in the wrong bank silently.

``ShopSettings.trusted_card_terminal_ids`` is still written, but only from
here, and only as a MIRROR of the active rows. It is the contract older clients
know, both to read and to PATCH, and this module is what keeps the two from
drifting: a PATCH of that list is reconciled into rows, and any change to the
rows rewrites the list.
"""

from django.db import transaction

from .card_receipts import normalize_terminal_id, terminal_ids_match
from .models import CardTerminal


def normalize(value) -> str:
    """The stored spelling of a terminal id: upper case, alphanumeric only.

    Deliberately NOT ``normalize_terminal_id``, which folds confusable glyphs
    (O→0, S→5) for *comparison*. Folding is right when matching a slip that may
    have been OCR'd; storing the folded form would show the owner a terminal id
    that is not the one printed on their machine.
    """
    return "".join(
        character for character in str(value or "").upper() if character.isalnum()
    )


def trusted_terminal_ids():
    """Every terminal the shop currently claims, for the trust check.

    Empty means "the shop has not restricted terminals", which allows any — the
    long-standing default, and the behaviour of a shop that never opened this
    screen.
    """
    return list(
        CardTerminal.objects.filter(is_active=True).values_list(
            "terminal_id", flat=True
        )
    )


def terminal_for_receipt_id(terminal_id, *, tolerant=False):
    """The configured terminal a slip's id names, or ``None``.

    Matching is the trust check's, to the letter, so a receipt can never be
    trusted by one rule and routed by another. ``tolerant`` allows the single
    character of slack an OCR'd id gets.
    """
    read_value = normalize_terminal_id(terminal_id)
    if not read_value:
        return None
    for terminal in CardTerminal.objects.filter(is_active=True).select_related(
        "money_account"
    ):
        if terminal_ids_match(
            read_value, normalize_terminal_id(terminal.terminal_id), tolerant=tolerant
        ):
            return terminal
    return None


def account_for_receipt(receipt_data):
    """The bank account the machine that printed this slip settles into.

    ``None`` whenever anything is unsaid — no terminal id on the slip, a
    terminal the shop has not registered, or one registered without an account.
    Every one of those means "route it the way you always did", never a guess:
    a payment filed under the wrong bank is worse than one filed under the
    default, because the owner reconciling a statement has no way to see it.
    """
    if not receipt_data:
        return None
    terminal_id = receipt_data.get("terminal_id") or (
        receipt_data.get("fields") or {}
    ).get("TerminalId")
    validation_method = str(receipt_data.get("validation_method") or "")
    terminal = terminal_for_receipt_id(
        terminal_id, tolerant=validation_method.endswith("ocr")
    )
    return terminal.money_account if terminal is not None else None


@transaction.atomic
def sync_from_id_list(terminal_ids):
    """Reconcile the registry against a bare list of ids.

    This is the old contract: a client that knows nothing about banks PATCHes
    ``trusted_card_terminal_ids`` and expects that to be the whole truth. Rows
    it names are (re)activated, rows it omits are DEACTIVATED rather than
    deleted — deleting would throw away the bank mapping the owner set on a
    newer client, and an old client toggling a terminal off and on again must
    not silently unlink its account.
    """
    wanted = []
    seen = set()
    for value in terminal_ids or []:
        terminal_id = normalize(value)
        if terminal_id and terminal_id not in seen:
            seen.add(terminal_id)
            wanted.append(terminal_id)

    existing = {
        terminal.terminal_id: terminal for terminal in CardTerminal.objects.all()
    }
    for order, terminal_id in enumerate(wanted):
        terminal = existing.get(terminal_id)
        if terminal is None:
            CardTerminal.objects.create(terminal_id=terminal_id, display_order=order)
        elif not terminal.is_active or terminal.display_order != order:
            terminal.is_active = True
            terminal.display_order = order
            terminal.save(update_fields=["is_active", "display_order", "updated_at"])
    stale = [
        terminal.pk
        for terminal_id, terminal in existing.items()
        if terminal_id not in seen and terminal.is_active
    ]
    if stale:
        CardTerminal.objects.filter(pk__in=stale).update(is_active=False)
    refresh_settings_mirror()


def refresh_settings_mirror():
    """Rewrite ``ShopSettings.trusted_card_terminal_ids`` from the rows.

    The only writer of that field. Called after every change to the registry so
    a client reading the settings blob — and the verification path, which still
    has shops on older builds — sees the same list this module would answer.
    """
    from apps.core.models import ShopSettings

    settings = ShopSettings.load()
    mirror = trusted_terminal_ids()
    if list(settings.trusted_card_terminal_ids or []) != mirror:
        settings.trusted_card_terminal_ids = mirror
        settings.save(update_fields=["trusted_card_terminal_ids"])


__all__ = [
    "account_for_receipt",
    "normalize",
    "refresh_settings_mirror",
    "sync_from_id_list",
    "terminal_for_receipt_id",
    "trusted_terminal_ids",
]
