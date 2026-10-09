"""How the Daftar wallet appears in the shop's own books — the one place that decides it.

The owner's decision: **the wallet is an asset.** Money paid into it has not
been spent; it has moved, from the shop's bank to the company. It is spent
when the shop uses it, and only then is it an expense — or, for the cards the
till sells, a cost.

* **A paid top-up** moves money from the routed bank account (from outside the
  shop when it has none) into «محفظة دفتر», a money account of the provider
  kind: the money position shows it beside the shop's cash, like a provider
  float, never inside the cash total. Booked once, on the day the gateway took
  the money.
* **Spending the wallet** — money moved into the SMS balance, a plan paid
  for — is an expense in the wallet's category («خدمات دفتر»), paid FROM
  «محفظة دفتر» (``Expense.money_account``), on the day it happened. The
  treasury subtracts it from that account and from no bank.
* **Money moved into the voucher balance** is not spent yet either: it moves
  from «محفظة دفتر» into the «كروت دفتر» float (``IntegrationAccount``'s own
  money account), and every card sold draws that float at the cost the relay
  actually charged (``IntegrationFulfillment.cost``, which is also the line's
  ``unit_cost``), as every provider float does. A card's cost is counted once:
  when it is sold.
* **Switched off** (``WalletSettings.record_topups_as_expenses`` — the app's
  name for it, from when a top-up was booked as an expense — and a top-up's own
  ``record_as_expense``, decided when it starts): nothing is booked for that
  money, neither its top-up nor its SMS and plan spending. Money moved into the
  voucher balance is the one exception: every card sold books its cost against
  the «كروت دفتر» float whatever this says, so the move is still booked — as
  money from outside the shop's books — or the float would read negative from
  the first card.

**Legacy.** Before this, a paid top-up was booked as an expense. Those stay as
they were: nothing here touches a top-up that already has one. At the
switch-over — the first booking under these rules — the part of the wallet that
was booked as an expense when it was paid in is remembered once
(``WalletSettings.prebooked_balance`` = min(main balance then, Σ paid top-ups
booked as expenses)). SMS and plan spending consumes it first and books nothing
for that part (it was booked when it was paid in, and booking it again would
count it twice); a spend's row says how much it consumed. Money moved into the
voucher balance never consumes it.

**Closed periods**, for every booking here: dated on the day it happened; when
that day is in a closed period, dated today and saying why; when today is
closed too, nothing is booked and the reason (``period_locked``) is kept for
the wallet sync to retry.

**Exactly once.** A top-up carries what it became (``transfer`` and its
``transfer_booked_at``); a spend is one ``WalletSpend`` row per relay movement,
keyed on the relay's own reference, carrying its expense or transfer. Neither
stamp is ever cleared, so a booking the owner deleted is never made again
behind their back. A booking that fails never fails the call that made the
movement: the money moved on the relay either way, and the sync retries.
"""

from __future__ import annotations

import logging
from decimal import ROUND_HALF_UP, Decimal

from django.db import transaction
from django.db.models import Q, Sum
from django.utils import timezone

from apps.core.period_lock import period_is_locked
from apps.expenses.models import Expense, ExpenseCategory
from apps.expenses.services import create_expense

from .models import WalletSettings, WalletSpend, WalletTopUp

logger = logging.getLogger(__name__)

#: The wallet's account in the money position.
WALLET_ACCOUNT_NAME = "محفظة دفتر"
#: Where the wallet's spending is filed unless the owner picked another.
WALLET_EXPENSE_CATEGORY_NAME = "خدمات دفتر"
#: The relay provider whose float money moved into the voucher balance funds.
VOUCHERS_PROVIDER = "pointy"
#: Local bank cards through Dafa, and Plutu's card checkout that it replaced
#: (old top-ups keep the name).
TOPUP_METHOD_BANK_CARDS = "dafa_moamalat"
TOPUP_METHOD_PLUTU_CARDS = "plutu_localbankcards"
#: How each payment method is named in the books.
METHOD_NAMES = {
    TOPUP_METHOD_BANK_CARDS: "بطاقة مصرفية محلية",
    TOPUP_METHOD_PLUTU_CARDS: "بطاقة مصرفية محلية",
    "dafa_sadad": "سداد",
    "dafa_edfali": "إدفعلي",
    "dafa_mobicash": "موبي كاش",
    "dafa_yussor_pay": "يسر باي",
    "dafa_masrafi_pay": "مصرفي باي",
    "dafa_sahara_pay": "صحارى باي",
    "bank_transfer": "تحويل مصرفي",
}
#: The books keep two places; the relay keeps the dirham's three.
_CENT = Decimal("0.01")
_ZERO = Decimal("0")


def method_name(method: str) -> str:
    return METHOD_NAMES.get(method, "بوابة الدفع")


# --- the wallet's account ---------------------------------------------------------
def wallet_account():
    """«محفظة دفتر» in the money position, made on first need.

    Remembered on the settings row (locked) rather than found by name, so the
    owner may rename it and two first bookings at once still make one.
    """
    from apps.treasury.models import MoneyAccount

    with transaction.atomic():
        settings = WalletSettings.objects.select_for_update().get_or_create(pk=1)[0]
        if settings.money_account_id is not None:
            return settings.money_account
        account = MoneyAccount.objects.create(
            name=WALLET_ACCOUNT_NAME,
            kind=MoneyAccount.Kind.PROVIDER,
            # Never a default: untagged money must never land in the wallet.
            is_default=False,
        )
        settings.money_account = account
        settings.save(update_fields=["money_account", "updated_at"])
        return account


def expense_category():
    """The category the wallet's spending is filed under, made on first use."""
    with transaction.atomic():
        settings = WalletSettings.objects.select_for_update().get_or_create(pk=1)[0]
        if settings.expense_category is not None:
            return settings.expense_category
        category, _ = ExpenseCategory.objects.get_or_create(
            name=WALLET_EXPENSE_CATEGORY_NAME,
            defaults={"display_order": 9},
        )
        settings.expense_category = category
        settings.save(update_fields=["expense_category", "updated_at"])
        return category


def _vouchers_float():
    """The «كروت دفتر» float's money account, and the account behind it.

    The provider account is made switched off when the owner has never turned
    it on: moving money in must not start selling.
    """
    from apps.integrations import float_ledger
    from apps.integrations.models import IntegrationAccount

    account, _ = IntegrationAccount.objects.get_or_create(
        provider=VOUCHERS_PROVIDER, defaults={"is_active": False}
    )
    return float_ledger.ensure_money_account(account)


# --- the day it is booked on ---------------------------------------------------------
def _booking_day(day, *, verb: str):
    """``(day to book on, note)``, or ``(None, "")`` when today is closed too."""
    if not period_is_locked(day):
        return day, ""
    today = timezone.localdate()
    if period_is_locked(today):
        return None, ""
    return today, f"{verb} في {day:%Y-%m-%d} ضمن فترة مغلقة، فسُجّل بتاريخ اليوم."


# --- the switch-over ---------------------------------------------------------------------
def ensure_switched_over(*, main_balance=None) -> bool:
    """Remember, once, how much of the wallet was already booked as an expense.

    ``main_balance`` is the relay's main balance as just answered, when the
    caller has one. It is only needed when some top-up was booked as an expense
    — a shop that never did that has nothing to remember — and is otherwise
    read from the relay. False when it is needed and cannot be read; the caller
    books nothing yet, and the sync tries again.

    The balance is taken back to before every movement these rules have still
    to book: a paid top-up not yet booked is in it, but is new money, never
    booked as an expense; a spend not yet booked is out of it, but was paid
    from what was there.
    """
    if WalletSettings.load().books_switched_at is not None:
        return True
    expensed = _sum(
        WalletTopUp.objects.filter(status=WalletTopUp.Status.PAID, expense_booked_at__isnull=False)
    )
    prebooked = _ZERO
    if expensed > 0:
        if main_balance is None:
            main_balance = _read_main_balance()
            if main_balance is None:
                return False
        unbooked_in = _sum(
            WalletTopUp.objects.filter(
                status=WalletTopUp.Status.PAID,
                record_as_expense=True,
                expense_booked_at__isnull=True,
                transfer_booked_at__isnull=True,
            )
        )
        unbooked_out = _sum(
            WalletSpend.objects.filter(booked_at__isnull=True, record_in_books=True)
        )
        before = Decimal(main_balance) - unbooked_in + unbooked_out
        prebooked = max(_ZERO, min(before, expensed))
    with transaction.atomic():
        settings = WalletSettings.objects.select_for_update().get_or_create(pk=1)[0]
        if settings.books_switched_at is None:
            settings.books_switched_at = timezone.now()
            settings.prebooked_balance = prebooked
            settings.save(update_fields=["books_switched_at", "prebooked_balance", "updated_at"])
    return True


def _read_main_balance():
    from .services import WalletError, read_main_balance

    try:
        return read_main_balance()
    except WalletError as error:
        logger.info("cannot switch the wallet's books over yet: %s", error.code)
        return None


def _sum(queryset) -> Decimal:
    return queryset.aggregate(total=Sum("amount"))["total"] or _ZERO


def _consume_prebooked(amount) -> Decimal:
    """Take up to ``amount`` from the money already booked as an expense."""
    settings = WalletSettings.objects.select_for_update().get_or_create(pk=1)[0]
    available = settings.prebooked_balance or _ZERO
    covered = min(available, Decimal(amount))
    if covered > 0:
        settings.prebooked_balance = available - covered
        settings.save(update_fields=["prebooked_balance", "updated_at"])
    return max(covered, _ZERO)


# --- a paid top-up ------------------------------------------------------------------------
def _owes_booking(topup) -> bool:
    return (
        topup.status == WalletTopUp.Status.PAID and topup.record_as_expense and not topup.is_booked
    )


def book_topup(topup_id):
    """Book a paid top-up once: money moved from the bank into the wallet.

    Never raises: the top-up is paid either way, and a failed booking is kept
    on the top-up (``expense_error``) for the sync to retry.
    """
    try:
        topup = WalletTopUp.objects.get(pk=topup_id)
        if not _owes_booking(topup):
            return topup
        if not ensure_switched_over():
            _note_topup_error(topup_id, "books_switching")
            return WalletTopUp.objects.get(pk=topup_id)
        with transaction.atomic():
            topup = WalletTopUp.objects.select_for_update().get(pk=topup_id)
            if not _owes_booking(topup):
                return topup
            paid_on = timezone.localdate(topup.paid_at or timezone.now())
            day, note = _booking_day(paid_on, verb="دُفع")
            if day is None:
                topup.expense_error = "period_locked"
                topup.save(update_fields=["expense_error", "updated_at"])
                return topup
            topup.transfer = _move_in(topup, day=day, note=note)
            topup.transfer_booked_at = timezone.now()
            topup.expense_error = ""
            topup.save(
                update_fields=["transfer", "transfer_booked_at", "expense_error", "updated_at"]
            )
            return topup
    except Exception:
        logger.exception("booking wallet top-up %s failed", topup_id)
        _note_topup_error(topup_id, "booking_failed")
        return WalletTopUp.objects.get(pk=topup_id)


def _move_in(topup, *, day, note):
    from apps.treasury.models import MoneyAccount, MoneyTransfer
    from apps.treasury.position import routed_account

    reason = f"شحن محفظة دفتر — {method_name(topup.method)}"
    if topup.test_mode:
        reason += " (تجريبي)"
    if note:
        reason += f" · {note}"
    return MoneyTransfer.objects.create(
        # Where a card or transfer payment the shop made leaves from. A shop
        # with no bank account paid it from outside the books.
        from_account=routed_account(MoneyAccount.Kind.BANK),
        to_account=wallet_account(),
        amount=topup.amount.quantize(_CENT, rounding=ROUND_HALF_UP),
        moved_at=day,
        reason=reason[:255],
        reference=topup.invoice_no[:128],
        created_by=topup.requested_by,
    )


def _note_topup_error(topup_id, code: str) -> None:
    WalletTopUp.objects.filter(
        pk=topup_id, expense_booked_at__isnull=True, transfer_booked_at__isnull=True
    ).update(expense_error=code, updated_at=timezone.now())


def owed_topups(*, since):
    """Paid top-ups these books still owe a row, for the sync."""
    return WalletTopUp.objects.filter(
        status=WalletTopUp.Status.PAID,
        record_as_expense=True,
        expense_booked_at__isnull=True,
        transfer_booked_at__isnull=True,
        relay_created_at__gte=since,
    )


# --- spending it ----------------------------------------------------------------------------
def record_spend(
    *, kind, relay_reference, amount, description, happened_on, user=None, main_balance=None
):
    """Remember one spend of the main wallet and book it. Never raises.

    ``main_balance`` is the relay's main balance after it, as its answer said.
    A replayed answer is the same row (``relay_reference``) and books nothing
    again.
    """
    try:
        spend, _ = WalletSpend.objects.get_or_create(
            kind=kind,
            relay_reference=relay_reference[:128],
            defaults={
                "amount": Decimal(amount),
                "description": description[:255],
                "happened_on": happened_on,
                "requested_by": user if getattr(user, "is_authenticated", False) else None,
                "record_in_books": WalletSettings.load().record_topups_as_expenses,
            },
        )
    except Exception:
        logger.exception("recording wallet spend %s failed", relay_reference)
        return None
    return book_spend(spend.pk, main_balance=main_balance)


def _owes_spend_booking(spend) -> bool:
    # The voucher float is always booked: the cards drawn from it always are.
    return spend.booked_at is None and (
        spend.record_in_books or spend.kind == WalletSpend.Kind.VOUCHERS
    )


def book_spend(spend_id, *, main_balance=None):
    """Book one spend once: an expense paid from the wallet, or (vouchers) a
    move into the voucher float. Never raises; see ``book_topup``."""
    try:
        spend = WalletSpend.objects.get(pk=spend_id)
        if not _owes_spend_booking(spend):
            return spend
        if not ensure_switched_over(main_balance=main_balance):
            _note_spend_error(spend_id, "books_switching")
            return WalletSpend.objects.get(pk=spend_id)
        with transaction.atomic():
            spend = WalletSpend.objects.select_for_update().get(pk=spend_id)
            if not _owes_spend_booking(spend):
                return spend
            day, note = _booking_day(spend.happened_on, verb="حدث")
            if day is None:
                spend.error = "period_locked"
                spend.save(update_fields=["error", "updated_at"])
                return spend
            fields = ["booked_at", "error", "updated_at"]
            if spend.kind == WalletSpend.Kind.VOUCHERS:
                spend.transfer = _move_to_vouchers(spend, day=day, note=note)
                fields.append("transfer")
            else:
                spend.prebooked_amount = _consume_prebooked(spend.amount)
                fields.append("prebooked_amount")
                rest = (spend.amount - spend.prebooked_amount).quantize(
                    _CENT, rounding=ROUND_HALF_UP
                )
                if rest > 0:
                    spend.expense = _spend_expense(spend, amount=rest, day=day, note=note)
                    fields.append("expense")
            spend.booked_at = timezone.now()
            spend.error = ""
            spend.save(update_fields=fields)
            return spend
    except Exception:
        logger.exception("booking wallet spend %s failed", spend_id)
        _note_spend_error(spend_id, "booking_failed")
        return WalletSpend.objects.filter(pk=spend_id).first()


def _spend_expense(spend, *, amount, day, note):
    notes = [f"دُفع من {WALLET_ACCOUNT_NAME}، رقم الحركة {spend.relay_reference}."]
    if spend.prebooked_amount > 0:
        notes.append(
            f"{spend.prebooked_amount:.3f} منها من رصيد سُجّل مصروفاً عند شحن المحفظة، "
            "فلم يُسجّل مرة أخرى."
        )
    if note:
        notes.append(note)
    return create_expense(
        user=spend.requested_by,
        category=expense_category(),
        description=spend.description,
        amount=amount,
        payment_method=Expense.PaymentMethod.TRANSFER,
        money_account=wallet_account(),
        spent_at=day,
        reference=spend.relay_reference[:128],
        notes="\n".join(notes),
    )


def _move_to_vouchers(spend, *, day, note):
    from apps.treasury.models import MoneyTransfer

    reason = "تحويل إلى رصيد كروت دفتر"
    if not spend.record_in_books:
        # The wallet is kept out of these books, so the money arrives from
        # outside them — as a payment from the owner's pocket would.
        reason += " (من خارج دفاتر المحل)"
    if note:
        reason += f" · {note}"
    return MoneyTransfer.objects.create(
        from_account=wallet_account() if spend.record_in_books else None,
        to_account=_vouchers_float(),
        amount=spend.amount.quantize(_CENT, rounding=ROUND_HALF_UP),
        moved_at=day,
        reason=reason[:255],
        reference=spend.relay_reference[:128],
        created_by=spend.requested_by,
    )


def _note_spend_error(spend_id, code: str) -> None:
    WalletSpend.objects.filter(pk=spend_id, booked_at__isnull=True).update(
        error=code, updated_at=timezone.now()
    )


def owed_spends(*, since):
    """Spending these books still owe a row, for the sync."""
    return WalletSpend.objects.filter(
        Q(record_in_books=True) | Q(kind=WalletSpend.Kind.VOUCHERS),
        booked_at__isnull=True,
        created_at__gte=since,
    )
