"""The Daftar wallet, as the shop's backend serves it to the app.

The balance and its ledger live on the relay; this module reads them for the
app, starts top-ups, sends the payer's code, and keeps the shop's own books. A
paid top-up becomes one expense («خدمات دفتر») when the shop wants that —
exactly once, however many times the top-up is read back: by the confirm that
paid it, by the app polling while the owner pays on the gateway's page, by the
owner opening the wallet later, or by the sync task catching a payment nobody
was watching (the owner closed the app; the company confirmed it by hand).

Spending the wallet books nothing: the money left the shop when it was paid
in. The owner moves some of it into the SMS balance, which every message is
paid from, and pays for the plans — remote access, the assistant — from the
main wallet, a period at a time.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import timedelta, timezone as dt_timezone
from decimal import Decimal, InvalidOperation

from django.core.exceptions import ImproperlyConfigured
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from apps.core.models import RelayInstallation
from apps.core.period_lock import period_is_locked
from apps.core.relay import (
    RelayControlError,
    mirror_sms_wallet,
    scoped_relay_client,
    sync_relay_installation,
)
from apps.expenses.models import Expense, ExpenseCategory
from apps.expenses.services import create_expense

from .models import WalletSettings, WalletTopUp

logger = logging.getLogger(__name__)

#: Where top-ups are filed unless the owner picked another category.
WALLET_EXPENSE_CATEGORY_NAME = "خدمات دفتر"
#: Local bank cards through Dafa: what a request without a method means, as
#: it did when Plutu's card checkout was the only way to pay.
TOPUP_METHOD_BANK_CARDS = "dafa_moamalat"
#: Plutu's card checkout, which Dafa replaced. Old top-ups keep the name.
TOPUP_METHOD_PLUTU_CARDS = "plutu_localbankcards"
#: How each method is named in the books, and how the money left the shop: a
#: bank card is a card payment, a mobile wallet or bank app is a transfer.
_METHOD_BOOKING = {
    TOPUP_METHOD_BANK_CARDS: ("بطاقة مصرفية محلية", Expense.PaymentMethod.CARD),
    TOPUP_METHOD_PLUTU_CARDS: ("بطاقة مصرفية محلية", Expense.PaymentMethod.CARD),
    "dafa_sadad": ("سداد", Expense.PaymentMethod.TRANSFER),
    "dafa_edfali": ("إدفعلي", Expense.PaymentMethod.TRANSFER),
    "dafa_mobicash": ("موبي كاش", Expense.PaymentMethod.TRANSFER),
    "dafa_yussor_pay": ("يسر باي", Expense.PaymentMethod.TRANSFER),
    "dafa_masrafi_pay": ("مصرفي باي", Expense.PaymentMethod.TRANSFER),
    "dafa_sahara_pay": ("صحارى باي", Expense.PaymentMethod.TRANSFER),
}
#: Relay calls that wait on the gateway. Starting a payment can take the
#: provider a while; a confirm may be followed by reading the payment back. The
#: relay gives each gateway call 20 seconds, so these outlast it.
START_TIMEOUT = 30
CONFIRM_TIMEOUT = 50
READ_TIMEOUT = 25
#: How far back the sync keeps asking about top-ups that could still change.
SYNC_LOOKBACK = timedelta(days=7)
PAGE_LIMIT = 50
_MONEY_PLACES = Decimal("0.01")

# The Arabic sentence behind every code the app can meet. The app maps the
# codes it knows to its own strings; this is the fallback it shows otherwise.
_MESSAGES = {
    "not_configured": "المحفظة غير متاحة: هذا المحل غير مربوط بخدمات دفتر بعد.",
    "relay_unreachable": "تعذر الوصول إلى خدمات دفتر. تحقق من اتصال الإنترنت ثم أعد المحاولة.",
    "relay_unauthorized": "رفضت خدمات دفتر بيانات هذا المحل. تواصل مع الدعم.",
    "wallet_unavailable": "المحفظة غير متاحة حالياً.",
    "topups_unconfigured": "شحن المحفظة غير متاح حالياً.",
    "invalid_amount": "المبلغ غير مقبول.",
    "amount_not_allowed": "بوابة الدفع لا تقبل هذا المبلغ.",
    "unsupported_method": "طريقة الدفع هذه غير متاحة.",
    "method_unavailable": "طريقة الدفع هذه غير متاحة الآن. اختر طريقة أخرى.",
    "invalid_phone": "رقم الهاتف غير صحيح. أدخل رقماً ليبياً مثل 0912345678.",
    "invalid_card_number": "رقم البطاقة غير صحيح.",
    "invalid_birth_year": "سنة الميلاد غير صحيحة.",
    "payer_rejected": "رفض مزوّد الخدمة عملية الدفع. تحقق من البيانات وأعد المحاولة.",
    "invalid_otp": "أدخل رمز التحقق كما وصلك.",
    "otp_rejected": "رمز التحقق غير صحيح. أعد إدخاله.",
    "otp_attempts_exceeded": "أُدخل رمز خاطئ مرات كثيرة. ابدأ عملية شحن جديدة.",
    "declined": "رُفضت عملية الدفع.",
    "topup_closed": "انتهت عملية الشحن هذه. ابدأ عملية جديدة.",
    "not_otp_method": "هذه العملية تُدفع في صفحة الدفع وليس برمز تحقق.",
    "confirm_unknown": "لم يصلنا رد بوابة الدفع. أعد إرسال الرمز نفسه.",
    "rate_limited": "بدأت عمليات شحن كثيرة. أعد المحاولة بعد دقيقة.",
    "in_flight": "عملية الشحن قيد التجهيز. أعد المحاولة بعد لحظات.",
    "gateway_busy": "بوابة الدفع مشغولة الآن. أعد المحاولة بعد قليل.",
    "gateway_unauthorized": "بوابة الدفع غير متاحة الآن. تواصل مع الدعم.",
    "gateway_rejected": "رفضت بوابة الدفع بدء العملية. أعد المحاولة لاحقاً.",
    "gateway_error": "تعذر بدء عملية الدفع. أعد المحاولة بعد قليل.",
    "outcome_unknown": "لم تكتمل المحاولة السابقة. ابدأ عملية شحن جديدة.",
    "not_found": "لم نجد عملية الشحن.",
    "insufficient_balance": "رصيد المحفظة لا يكفي. اشحن المحفظة ثم أعد المحاولة.",
    "plan_unavailable": "هذا الاشتراك غير متاح للدفع من المحفظة حالياً.",
    "plan_included": "هذه الخدمة مشمولة في اشتراكك بلا تاريخ انتهاء، فلا حاجة للدفع.",
    "invalid_periods": "عدد الأشهر غير مقبول.",
    "relay_error": "تعذر على خدمات دفتر إتمام الطلب. أعد المحاولة.",
}


class WalletError(Exception):
    """A wallet call that could not be answered, with a code the app maps."""

    def __init__(self, code, *, status=502, extra=None):
        self.code = code
        self.status = status
        self.extra = extra or {}
        super().__init__(_MESSAGES.get(code, _MESSAGES["relay_error"]))

    @property
    def message(self):
        return str(self)

    def payload(self):
        return {"code": self.code, "detail": self.message, **self.extra}


# --- relay access -------------------------------------------------------------


def _relay():
    installation = RelayInstallation.load()
    if installation is None or not installation.access_token:
        raise WalletError("not_configured", status=503)
    try:
        return installation, scoped_relay_client(installation)
    except ImproperlyConfigured as exc:
        raise WalletError("not_configured", status=503) from exc


def _relay_body(exc):
    try:
        body = json.loads(exc.body or "")
    except (TypeError, ValueError):
        return {}
    return body if isinstance(body, dict) else {}


#: What a relay refusal carries that the app can use: the amount bounds, and
#: the gateway's own word on a payment — its code, its sentence (Arabic,
#: written for the payer), and how many codes are left.
_RELAY_EXTRA_KEYS = (
    "min_amount",
    "max_amount",
    "max_decimals",
    "gateway_code",
    "gateway_message",
    "attempts_left",
    "retryable",
    "balance",
    "amount",
    "max_periods",
)


def _wallet_error(exc: RelayControlError) -> WalletError:
    if exc.status_code is None:
        return WalletError("relay_unreachable", status=503)
    body = _relay_body(exc)
    code = str(body.get("code") or "")
    if exc.status_code == 401 or code == "unauthorized":
        return WalletError("relay_unauthorized", status=502)
    extra = {key: body[key] for key in _RELAY_EXTRA_KEYS if key in body}
    if not code:
        return WalletError("relay_error", status=502, extra=extra)
    # The relay's status is meaningful to the app (409 retry, 422 fix the
    # amount, 503 later); anything else it did not expect is a bad gateway.
    status = exc.status_code if exc.status_code in (404, 409, 422, 429, 503) else 502
    return WalletError(code, status=status, extra=extra)


def _call(request):
    try:
        return request()
    except RelayControlError as exc:
        error = _wallet_error(exc)
        # The failed top-up the relay recorded comes back in the error body:
        # keep the shop's copy in step, so the history shows it.
        top_up = _relay_body(exc).get("top_up")
        if isinstance(top_up, dict) and top_up.get("id"):
            error.extra["top_up"] = topup_payload(top_up, _mirror(top_up))
        raise error from exc


# --- the shop's copy ------------------------------------------------------------


def _decimal(value, default=Decimal("0")):
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return default


def _instant(value):
    if not value:
        return None
    parsed = parse_datetime(str(value))
    if parsed is not None and timezone.is_naive(parsed):
        parsed = timezone.make_aware(parsed, dt_timezone.utc)
    return parsed


def _mirror(remote, *, user=None, record_as_expense=None):
    """Store (or refresh) the shop's copy of a relay top-up."""
    relay_id = str(remote.get("id") or "")
    if not relay_id:
        raise WalletError("relay_error")
    fields = {
        "invoice_no": str(remote.get("invoice_no") or "")[:32],
        "method": str(remote.get("method") or "")[:40],
        "payer_hint": str(remote.get("payer_hint") or "")[:32],
        "amount": _decimal(remote.get("amount")),
        "status": str(remote.get("status") or WalletTopUp.Status.PENDING),
        "provider_transaction_id": str(remote.get("provider_transaction_id") or "")[:128],
        "test_mode": bool(remote.get("test_mode")),
        "error_code": str(remote.get("error_code") or "")[:64],
        "paid_at": _instant(remote.get("paid_at")),
    }
    created_at = _instant(remote.get("created_at")) or timezone.now()
    if record_as_expense is None:
        # First sight of a top-up this backend did not start. Already paid
        # means it was paid before these books knew of it — after a factory
        # reset, say — so it is not back-dated into them as a new expense.
        record_as_expense = (
            fields["status"] != WalletTopUp.Status.PAID
            and WalletSettings.load().record_topups_as_expenses
        )
    topup, created = WalletTopUp.objects.get_or_create(
        relay_id=relay_id,
        defaults={
            **fields,
            "relay_created_at": created_at,
            "requested_by": user,
            "record_as_expense": record_as_expense,
            "synced_at": timezone.now(),
        },
    )
    if created:
        return topup
    changed = [name for name, value in fields.items() if getattr(topup, name) != value]
    for name in changed:
        setattr(topup, name, fields[name])
    topup.synced_at = timezone.now()
    topup.save(update_fields=[*changed, "synced_at", "updated_at"])
    return topup


def _refresh(remote, **mirror_kwargs):
    """Mirror a relay top-up and, when it is paid, settle the books."""
    topup = _mirror(remote, **mirror_kwargs)
    if topup.status == WalletTopUp.Status.PAID:
        topup = book_topup_expense(topup.pk)
    return topup


def topup_payload(remote, topup=None):
    """A top-up as the app sees it: the relay's facts plus the shop's books."""
    payload = {
        "id": remote.get("id"),
        "invoice_no": remote.get("invoice_no", ""),
        "method": remote.get("method", ""),
        "kind": remote.get("kind", ""),
        "payer_hint": remote.get("payer_hint", ""),
        "amount": remote.get("amount", "0"),
        "status": remote.get("status", ""),
        "test_mode": bool(remote.get("test_mode")),
        "requested_by": remote.get("requested_by", ""),
        "provider_transaction_id": remote.get("provider_transaction_id", ""),
        "error_code": remote.get("error_code", ""),
        "confirmed_by": remote.get("confirmed_by", ""),
        "created_at": remote.get("created_at"),
        "paid_at": remote.get("paid_at"),
        "record_as_expense": None,
        "expense_id": None,
        "expense_error": "",
    }
    if remote.get("checkout_url"):
        payload["checkout_url"] = remote["checkout_url"]
    if remote.get("otp_attempts_left") is not None:
        payload["otp_attempts_left"] = remote["otp_attempts_left"]
    if topup is not None:
        payload["record_as_expense"] = topup.record_as_expense
        payload["expense_id"] = topup.expense_id
        payload["expense_error"] = topup.expense_error
    return payload


def _local_payload(topup):
    """A top-up from the shop's copy alone, for when the relay cannot be read."""
    return {
        "id": topup.relay_id,
        "invoice_no": topup.invoice_no,
        "method": topup.method,
        "kind": "",
        "payer_hint": topup.payer_hint,
        "amount": f"{topup.amount:.3f}",
        "status": topup.status,
        "test_mode": topup.test_mode,
        "requested_by": getattr(topup.requested_by, "username", "") or "",
        "provider_transaction_id": topup.provider_transaction_id,
        "error_code": topup.error_code,
        "confirmed_by": "",
        "created_at": topup.relay_created_at.isoformat(),
        "paid_at": topup.paid_at.isoformat() if topup.paid_at else None,
        "record_as_expense": topup.record_as_expense,
        "expense_id": topup.expense_id,
        "expense_error": topup.expense_error,
    }


def _payloads_with_books(remotes):
    """Relay top-ups annotated with the shop's copy, refreshing that copy."""
    payloads = []
    for remote in remotes:
        if not isinstance(remote, dict) or not remote.get("id"):
            continue
        payloads.append(topup_payload(remote, _refresh(remote)))
    return payloads


# --- the books ------------------------------------------------------------------


def wallet_settings_payload(settings=None):
    settings = settings or WalletSettings.load()
    category = settings.expense_category
    return {
        "record_topups_as_expenses": settings.record_topups_as_expenses,
        "expense_category": (
            {"id": category.pk, "name": category.name} if category is not None else None
        ),
        "default_expense_category_name": WALLET_EXPENSE_CATEGORY_NAME,
    }


def update_wallet_settings(*, record_topups_as_expenses=None, expense_category=...):
    settings = WalletSettings.load()
    fields = []
    if record_topups_as_expenses is not None:
        settings.record_topups_as_expenses = record_topups_as_expenses
        fields.append("record_topups_as_expenses")
    if expense_category is not ...:
        settings.expense_category = expense_category
        fields.append("expense_category")
    if fields:
        settings.save(update_fields=[*fields, "updated_at"])
    return settings


def _expense_category():
    """The category a top-up is filed under, made on first use."""
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


def book_topup_expense(topup_id):
    """Book a paid top-up as an expense, once: a card payment for a bank card,
    a transfer for a mobile wallet or bank app.

    The money left the shop's account on the day the gateway took it, so that
    is the expense's day — unless that day is in a closed period, in which case
    the expense is dated today (and says why) rather than reopening books that
    were reported. When today is closed too, nothing is booked and the reason
    is kept for the next sync.
    """
    try:
        with transaction.atomic():
            topup = WalletTopUp.objects.select_for_update().get(pk=topup_id)
            if (
                topup.status != WalletTopUp.Status.PAID
                or not topup.record_as_expense
                or topup.expense_booked_at is not None
            ):
                return topup
            paid_on = timezone.localdate(topup.paid_at or timezone.now())
            spent_at = paid_on
            method_name, payment_method = _METHOD_BOOKING.get(
                topup.method, ("بوابة الدفع", Expense.PaymentMethod.TRANSFER)
            )
            notes = [f"شحن محفظة دفتر، رقم العملية {topup.invoice_no}."]
            if topup.payer_hint:
                notes.append(f"دُفع من {method_name} {topup.payer_hint}.")
            if topup.provider_transaction_id:
                notes.append(f"رقم عملية بوابة الدفع: {topup.provider_transaction_id}.")
            if period_is_locked(spent_at):
                today = timezone.localdate()
                if period_is_locked(today):
                    topup.expense_error = "period_locked"
                    topup.save(update_fields=["expense_error", "updated_at"])
                    return topup
                notes.append(
                    f"دُفع في {paid_on:%Y-%m-%d} ضمن فترة مغلقة، فسُجّل بتاريخ اليوم."
                )
                spent_at = today
            description = f"شحن محفظة دفتر — {method_name}"
            if topup.test_mode:
                description += " (تجريبي)"
            expense = create_expense(
                user=topup.requested_by,
                category=_expense_category(),
                description=description,
                amount=topup.amount.quantize(_MONEY_PLACES),
                payment_method=payment_method,
                spent_at=spent_at,
                reference=topup.invoice_no,
                notes="\n".join(notes),
            )
            topup.expense = expense
            topup.expense_booked_at = timezone.now()
            topup.expense_error = ""
            topup.save(update_fields=["expense", "expense_booked_at", "expense_error", "updated_at"])
            return topup
    except Exception:
        # The top-up is paid either way; the books catch up on the next sync.
        logger.exception("booking wallet top-up %s as an expense failed", topup_id)
        WalletTopUp.objects.filter(pk=topup_id, expense_booked_at__isnull=True).update(
            expense_error="booking_failed", updated_at=timezone.now()
        )
        return WalletTopUp.objects.get(pk=topup_id)


# --- what the views call ----------------------------------------------------------


def wallet_overview():
    """Balance, top-up options, the latest top-ups and movements, and the shop's
    settings. When the relay cannot be read, the shop's own copy of its recent
    top-ups is still shown, with the reason."""
    settings = WalletSettings.load()
    try:
        installation, client = _relay()
        payload = _call(lambda: client.get_wallet(access_token=installation.access_token))
    except WalletError as error:
        recent = WalletTopUp.objects.select_related("requested_by")[:10]
        return {
            "available": False,
            "error": error.payload(),
            "balance": None,
            "currency": "LYD",
            "test_mode": False,
            "topups": None,
            "sms": None,
            "plans": [],
            "recent_topups": [_local_payload(topup) for topup in recent],
            "recent_entries": [],
            "settings": wallet_settings_payload(settings),
        }
    sms = payload.get("sms")
    _mirror_sms(sms, installation)
    return {
        "available": True,
        "error": None,
        "balance": payload.get("balance"),
        "currency": payload.get("currency", "LYD"),
        "updated_at": payload.get("updated_at"),
        "test_mode": bool(payload.get("test_mode")),
        "topups": payload.get("topups"),
        # A relay from before the SMS balance and the plans sends neither.
        "sms": sms if isinstance(sms, dict) else None,
        "plans": [plan for plan in payload.get("plans") or [] if isinstance(plan, dict)],
        "recent_topups": _payloads_with_books(payload.get("recent_topups") or []),
        "recent_entries": payload.get("recent_entries") or [],
        "settings": wallet_settings_payload(settings),
    }


def list_topups(*, before="", limit=PAGE_LIMIT):
    installation, client = _relay()
    payload = _call(
        lambda: client.list_wallet_topups(
            access_token=installation.access_token, limit=limit, before=before
        )
    )
    return {
        "topups": _payloads_with_books(payload.get("topups") or []),
        "has_more": bool(payload.get("has_more")),
    }


def list_entries(*, before="", limit=PAGE_LIMIT, kind="", account=""):
    """One account's statement: the main wallet (the default) or the SMS balance."""
    installation, client = _relay()
    payload = _call(
        lambda: client.list_wallet_entries(
            access_token=installation.access_token,
            limit=limit,
            before=before,
            kind=kind,
            account=account,
        )
    )
    return {
        "entries": payload.get("entries") or [],
        "has_more": bool(payload.get("has_more")),
    }


def start_topup(*, user, amount, method=TOPUP_METHOD_BANK_CARDS, idempotency_key="",
                record_as_expense=None, user_identifier="", birth_year=""):
    """Ask the relay to start a payment. Returns the top-up and what the payer
    does next: type the code their provider texted them (``next_action`` otp),
    or pay on ``checkout_url`` (hosted_page).

    ``user_identifier`` is the payer's phone or wallet card number and
    ``birth_year`` Sadad's second factor; both go to the relay and are never
    stored here — the relay hands back a masked hint. ``record_as_expense`` is
    the owner's choice for THIS top-up, defaulting to the saved setting; the
    switch in the sheet saves it as the new default.
    """
    installation, client = _relay()
    if record_as_expense is not None:
        update_wallet_settings(record_topups_as_expenses=record_as_expense)
    else:
        record_as_expense = WalletSettings.load().record_topups_as_expenses
    key = idempotency_key or f"topup-{uuid.uuid4()}"
    requested_by = _requested_by(user)
    payload = _call(
        lambda: client.create_wallet_topup(
            access_token=installation.access_token,
            amount=amount,
            method=method,
            idempotency_key=key,
            requested_by=requested_by,
            user_identifier=user_identifier,
            birth_year=birth_year,
            timeout=START_TIMEOUT,
        )
    )
    remote = payload.get("top_up") or {}
    topup = _mirror(
        remote,
        user=user if getattr(user, "is_authenticated", False) else None,
        record_as_expense=record_as_expense,
    )
    return {
        "top_up": topup_payload(remote, topup),
        "next_action": payload.get("next_action") or remote.get("kind") or "",
        "checkout_url": payload.get("checkout_url") or remote.get("checkout_url") or "",
        "replayed": bool(payload.get("replayed")),
    }


def _requested_by(user):
    """Who the relay records as having asked, as the shop names them."""
    if user is None or not getattr(user, "is_authenticated", False):
        return ""
    return (user.get_full_name() or user.get_username() or "")[:128]


def _mirror_sms(sms, installation=None):
    """Keep the shop's copy of its SMS balance in step, so SMS stops being
    offered the moment the money runs out — and starts again when it is moved in."""
    try:
        mirror_sms_wallet(sms, installation=installation)
    except Exception:  # noqa: BLE001 - the answer the app waits for matters more
        logger.exception("mirroring the SMS balance failed")


def allocate_to_sms(*, user, amount, idempotency_key=""):
    """Move money from the main wallet into the SMS balance. Returns both
    balances and the transfer; a retry with the same key moves nothing again."""
    installation, client = _relay()
    key = idempotency_key or f"sms-{uuid.uuid4()}"
    payload = _call(
        lambda: client.allocate_wallet_sms(
            access_token=installation.access_token,
            amount=amount,
            idempotency_key=key,
            requested_by=_requested_by(user),
            timeout=READ_TIMEOUT,
        )
    )
    sms = payload.get("sms")
    _mirror_sms(sms, installation)
    return {
        "balance": payload.get("balance"),
        "sms": sms if isinstance(sms, dict) else None,
        "transfer": payload.get("transfer") or {},
        "replayed": bool(payload.get("replayed")),
    }


def purchase_plan(*, user, plan, periods=1, idempotency_key=""):
    """Pay for ``periods`` periods of a plan from the main wallet. The relay
    charges it and moves the plan's end in one step; the shop's copy of its
    entitlements is then re-read, so the feature works on this backend at once."""
    installation, client = _relay()
    key = idempotency_key or f"plan-{uuid.uuid4()}"
    payload = _call(
        lambda: client.purchase_wallet_plan(
            access_token=installation.access_token,
            plan=plan,
            periods=periods,
            idempotency_key=key,
            requested_by=_requested_by(user),
            timeout=READ_TIMEOUT,
        )
    )
    try:
        sync_relay_installation(installation, client=client, push_shop_name=False)
    except (RelayControlError, ImproperlyConfigured) as exc:
        # Paid either way; the periodic sync brings the entitlement down.
        logger.warning("re-reading entitlements after a plan purchase failed: %s", exc)
    return {
        "plan": payload.get("plan") or {},
        "balance": payload.get("balance"),
        "entry": payload.get("entry") or {},
        "replayed": bool(payload.get("replayed")),
    }


def refresh_topup(relay_id):
    """Read one top-up from the relay and settle the books if it was paid."""
    installation, client = _relay()
    payload = _call(
        lambda: client.get_wallet_topup(
            access_token=installation.access_token, topup_id=relay_id, timeout=READ_TIMEOUT
        )
    )
    remote = payload.get("top_up") or {}
    return topup_payload(remote, _refresh(remote))


def confirm_topup(relay_id, otp):
    """Send the payer's code. A paid answer settles the books at once; a code
    the gateway took without a verdict (``code`` awaiting_gateway) leaves the
    app polling, like a bank card."""
    installation, client = _relay()
    payload = _call(
        lambda: client.confirm_wallet_topup(
            access_token=installation.access_token,
            topup_id=relay_id,
            otp=otp,
            timeout=CONFIRM_TIMEOUT,
        )
    )
    remote = payload.get("top_up") or {}
    return {"top_up": topup_payload(remote, _refresh(remote)), "code": str(payload.get("code") or "")}


def cancel_topup(relay_id):
    """Call off a top-up still waiting for its code."""
    installation, client = _relay()
    payload = _call(
        lambda: client.cancel_wallet_topup(access_token=installation.access_token, topup_id=relay_id)
    )
    remote = payload.get("top_up") or {}
    return {"top_up": topup_payload(remote, _refresh(remote))}


def sync_topups():
    """Catch payments nobody was watching. Asks the relay only when the shop has
    a top-up that could still change, or a paid one whose expense is owed."""
    since = timezone.now() - SYNC_LOOKBACK
    open_topups = WalletTopUp.objects.filter(
        status__in=WalletTopUp.OPEN_STATUSES, relay_created_at__gte=since
    )
    # Retried for as long as the relay is asked about open ones: past that the
    # top-up shows its expense_error in the app and the owner records it.
    owed = WalletTopUp.objects.filter(
        status=WalletTopUp.Status.PAID,
        record_as_expense=True,
        expense_booked_at__isnull=True,
        relay_created_at__gte=since,
    )
    for topup in owed.only("pk"):
        book_topup_expense(topup.pk)
    if not open_topups.exists():
        return {"asked_relay": False, "refreshed": 0}
    try:
        result = list_topups(limit=PAGE_LIMIT)
    except WalletError as error:
        logger.info("wallet sync skipped: %s", error.code)
        return {"asked_relay": True, "refreshed": 0, "error": error.code}
    return {"asked_relay": True, "refreshed": len(result["topups"])}
