"""The Daftar wallet, as the shop's backend serves it to the app.

The balance and its ledger live on the relay; this module reads them for the
app, starts top-ups, sends the payer's code, spends the wallet, and keeps the
shop's own books through :mod:`apps.wallet.books` — the one place that decides
what each movement becomes there (the wallet is an asset: a paid top-up moves
money from the bank into «محفظة دفتر»; spending it is an expense paid from it;
money moved into the voucher balance moves into the «كروت دفتر» float).

Every booking happens exactly once, however many times a movement is read
back: a top-up by the confirm that paid it, by the app polling while the owner
pays on the gateway's page, by the owner opening the wallet later, or by the
sync task catching a payment nobody was watching (the owner closed the app;
the company confirmed it by hand); a spend right after the relay answers it.

The owner moves money from the main wallet into the SMS balance, which every
message is paid from, and into the voucher balance, which every «كروت دفتر»
card is paid from, and pays for the plans — remote access, the assistant — from
the main wallet, a period at a time.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import timedelta, timezone as dt_timezone
from decimal import Decimal, InvalidOperation

from django.core.exceptions import ImproperlyConfigured
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from apps.core.models import RelayInstallation
from apps.core.relay import (
    RelayControlError,
    mirror_sms_wallet,
    scoped_relay_client,
    sync_relay_installation,
)

from . import books
from .books import (  # noqa: F401 - the app's names for them, kept here
    TOPUP_METHOD_BANK_CARDS,
    TOPUP_METHOD_PLUTU_CARDS,
    WALLET_EXPENSE_CATEGORY_NAME,
)
from .models import WalletSettings, WalletSpend, WalletTopUp

logger = logging.getLogger(__name__)

#: The plans as the books name them (the relay's own titles).
PLAN_TITLES = {
    "remote_access": "الوصول عن بُعد",
    "ai": "المساعد الذكي",
}
#: What moving money into the SMS balance, and into the voucher balance, is
#: called in the books.
SMS_SPEND_DESCRIPTION = "رصيد الرسائل"
VOUCHERS_SPEND_DESCRIPTION = "تحويل إلى رصيد كروت دفتر"
#: Relay calls that wait on the gateway. Starting a payment can take the
#: provider a while; a confirm may be followed by reading the payment back. The
#: relay gives each gateway call 20 seconds, so these outlast it.
START_TIMEOUT = 30
CONFIRM_TIMEOUT = 50
READ_TIMEOUT = 25
#: How far back the sync keeps asking about top-ups that could still change.
SYNC_LOOKBACK = timedelta(days=7)
PAGE_LIMIT = 50

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
    "bank_transfer_unavailable": "التحويل المصرفي غير متاح حالياً.",
    "invalid_channel": "اختر التطبيق الذي حوّلت به: لي باي أو ون باي.",
    "invalid_payer_bank": "اختر المصرف الذي حوّلت منه.",
    "invalid_payer_account": "رقم الحساب غير صحيح. أدخل الأرقام فقط.",
    "invalid_iban": "رقم IBAN غير صحيح. يبدأ بـ LY ويليه 23 رقماً.",
    "invalid_receipt": "أرفق إيصال التحويل: صورة أو ملف PDF.",
    "receipt_too_large": "الإيصال أكبر من 10 ميغابايت.",
    "too_many_reviews": "لديك تحويلات بانتظار التحقق. انتظر حتى نتحقق منها.",
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
    "max_receipt_bytes",
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
    status = exc.status_code if exc.status_code in (404, 409, 413, 422, 429, 503) else 502
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
        "error_detail": str(remote.get("error_detail") or "")[:500],
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
    if "status" in changed:
        _note_decision(topup)
    return topup


#: What the company decided about a bank transfer.
_DECIDED = (WalletTopUp.Status.PAID, WalletTopUp.Status.REJECTED)


def _note_decision(topup):
    """Stamp the moment this shop learned the company decided a bank transfer,
    and bring the owner's notifications up to date so the bell says so
    without waiting for its next sweep."""
    if topup.method != WalletTopUp.METHOD_BANK_TRANSFER or topup.status not in _DECIDED:
        return
    # Restamped on every decision: a rejected transfer the company later
    # confirms (the money turned up after all) is news again.
    now = timezone.now()
    WalletTopUp.objects.filter(pk=topup.pk).update(decided_at=now)
    topup.decided_at = now
    try:
        from apps.core.dispatch import enqueue_best_effort
        from apps.notifications.tasks import sync_business_notifications_task

        enqueue_best_effort(sync_business_notifications_task)
    except Exception:  # noqa: BLE001 - the sweep catches up on its own
        logger.warning("could not hurry the notification sweep", exc_info=True)


def _refresh(remote, **mirror_kwargs):
    """Mirror a relay top-up and, when it is paid, settle the books."""
    topup = _mirror(remote, **mirror_kwargs)
    if topup.status == WalletTopUp.Status.PAID:
        topup = books.book_topup(topup.pk)
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
        "error_detail": remote.get("error_detail", ""),
        "confirmed_by": remote.get("confirmed_by", ""),
        "created_at": remote.get("created_at"),
        "paid_at": remote.get("paid_at"),
        "record_as_expense": None,
        "expense_id": None,
        "transfer_id": None,
        "expense_error": "",
    }
    if remote.get("checkout_url"):
        payload["checkout_url"] = remote["checkout_url"]
    if isinstance(remote.get("transfer"), dict):
        payload["transfer"] = remote["transfer"]
    if remote.get("otp_attempts_left") is not None:
        payload["otp_attempts_left"] = remote["otp_attempts_left"]
    if topup is not None:
        payload["record_as_expense"] = topup.record_as_expense
        # A top-up booked before the wallet was an account in the books
        # carries its expense; one booked since, the money moved into it.
        payload["expense_id"] = topup.expense_id
        payload["transfer_id"] = topup.transfer_id
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
        "error_detail": topup.error_detail,
        "confirmed_by": "",
        "created_at": topup.relay_created_at.isoformat(),
        "paid_at": topup.paid_at.isoformat() if topup.paid_at else None,
        "record_as_expense": topup.record_as_expense,
        "expense_id": topup.expense_id,
        "transfer_id": topup.transfer_id,
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
    account = settings.money_account
    return {
        # The app's name for it: whether the wallet is kept in the shop's
        # books at all (``apps.wallet.books``).
        "record_topups_as_expenses": settings.record_topups_as_expenses,
        "expense_category": (
            {"id": category.pk, "name": category.name} if category is not None else None
        ),
        "default_expense_category_name": WALLET_EXPENSE_CATEGORY_NAME,
        # «محفظة دفتر» in the money position, once anything was booked to it.
        "money_account": (
            {"id": account.pk, "name": account.name} if account is not None else None
        ),
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
            "vouchers": None,
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
        # Nor, from before the voucher shop, the voucher balance.
        "vouchers": _vouchers_block(payload.get("vouchers")),
        "plans": [plan for plan in payload.get("plans") or [] if isinstance(plan, dict)],
        "recent_topups": _payloads_with_books(payload.get("recent_topups") or []),
        "recent_entries": payload.get("recent_entries") or [],
        "settings": wallet_settings_payload(settings),
    }


def read_main_balance():
    """The main wallet's balance, as the relay holds it now. Raises ``WalletError``."""
    installation, client = _relay()
    payload = _call(lambda: client.get_wallet(access_token=installation.access_token))
    balance = _decimal(payload.get("balance"), default=None)
    if balance is None:
        raise WalletError("relay_error")
    return balance


def _vouchers_block(vouchers):
    """The voucher balance as the app shows it, or ``None`` from a relay that
    sells no cards of its own. ``enabled`` is the shop's own switch: the owner
    turned «كروت دفتر» on in Integrations."""
    if not isinstance(vouchers, dict):
        return None
    _mirror_vouchers(vouchers)
    from apps.integrations.models import IntegrationAccount

    return {
        "balance": vouchers.get("balance"),
        "configured": bool(vouchers.get("configured")),
        "test_mode": bool(vouchers.get("test_mode")),
        "enabled": IntegrationAccount.objects.filter(
            provider=books.VOUCHERS_PROVIDER, is_active=True
        ).exists(),
    }


def _mirror_vouchers(vouchers):
    """Keep the «كروت دفتر» account's balance — the voucher balance — in step,
    so the till warns about a card the balance cannot pay for. Best-effort,
    and a plain update: a balance moving is not a settings change."""
    balance = _decimal((vouchers or {}).get("balance"), default=None)
    if balance is None:
        return
    from apps.integrations.models import IntegrationAccount

    try:
        IntegrationAccount.objects.filter(provider=books.VOUCHERS_PROVIDER).exclude(
            balance=balance.quantize(Decimal("0.01"))
        ).update(balance=balance.quantize(Decimal("0.01")), balance_at=timezone.now())
    except Exception:  # noqa: BLE001 - the answer the app waits for matters more
        logger.exception("mirroring the voucher balance failed")


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


#: Receipts the relay keeps: a photo or the bank's PDF.
MAX_RECEIPT_BYTES = 10 * 1024 * 1024
#: How old a receipt the phone sent may be when it is attached to a transfer.
COMPANION_RECEIPT_MAX_AGE = timedelta(hours=2)


def start_bank_transfer(
    *,
    user,
    amount,
    channel,
    payer_bank,
    payer_account,
    payer_iban,
    to_account="",
    receipt_file=None,
    receipt_attachment_id=None,
    idempotency_key="",
    record_as_expense=None,
):
    """Send a transfer the shop made to the company's account, with its receipt.

    The receipt is a file the app uploaded, or what the paired phone sent
    (``receipt_attachment_id``). Photos are re-encoded from their bytes (a HEIC
    from an iPhone becomes a JPEG an operator's browser can show); a PDF goes
    as it is. The relay keeps the top-up in review until the company finds the
    money; the app shows it waiting, and the owner is told the outcome.
    """
    installation, client = _relay()
    receipt, name, content_type = _receipt_bytes(
        user=user, receipt_file=receipt_file, attachment_id=receipt_attachment_id
    )
    if record_as_expense is not None:
        update_wallet_settings(record_topups_as_expenses=record_as_expense)
    else:
        record_as_expense = WalletSettings.load().record_topups_as_expenses
    key = idempotency_key or f"transfer-{uuid.uuid4()}"
    fields = {
        "amount": str(amount),
        "idempotency_key": key,
        "requested_by": _requested_by(user),
        "channel": channel,
        "payer_bank": payer_bank,
        "payer_account": payer_account,
        "payer_iban": payer_iban,
    }
    if to_account:
        fields["to_account"] = to_account
    payload = _call(
        lambda: client.create_wallet_bank_transfer(
            access_token=installation.access_token,
            fields=fields,
            receipt=receipt,
            receipt_name=name,
            receipt_type=content_type,
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
        "next_action": payload.get("next_action") or "bank_transfer",
        "replayed": bool(payload.get("replayed")),
    }


def _receipt_bytes(*, user, receipt_file, attachment_id):
    """The receipt as (bytes, name, content type), or ``WalletError``."""
    from apps.attachments.image_normalization import normalize_uploaded_image

    if receipt_file is None and attachment_id:
        receipt_file = _companion_receipt(user, attachment_id)
    if receipt_file is None:
        raise WalletError("invalid_receipt", status=422)
    if getattr(receipt_file, "size", 0) > MAX_RECEIPT_BYTES:
        raise WalletError("receipt_too_large", status=413, extra={"max_receipt_bytes": MAX_RECEIPT_BYTES})
    receipt_file.seek(0)
    head = receipt_file.read(5)
    receipt_file.seek(0)
    name = str(getattr(receipt_file, "name", "") or "receipt")
    if head == b"%PDF-":
        return receipt_file.read(), name, "application/pdf"
    normalized = normalize_uploaded_image(receipt_file)
    if normalized is None:
        raise WalletError("invalid_receipt", status=422)
    data = normalized.read()
    if len(data) > MAX_RECEIPT_BYTES:
        raise WalletError("receipt_too_large", status=413, extra={"max_receipt_bytes": MAX_RECEIPT_BYTES})
    return data, normalized.name, normalized.content_type


def _companion_receipt(user, attachment_id):
    """What this user's paired phone just sent for this transfer.

    Only a capture this user asked their phone for, in the last two hours: an
    attachment id is not a way to send the company any file in the shop.
    """
    from django.core.files.uploadedfile import SimpleUploadedFile

    from apps.attachments.models import Attachment
    from apps.attachments.services import open_attachment
    from apps.companion.models import CompanionCaptureRequest

    try:
        attachment = Attachment.objects.get(pk=int(attachment_id), status=Attachment.Status.ACTIVE)
    except (Attachment.DoesNotExist, TypeError, ValueError):
        raise WalletError("invalid_receipt", status=422) from None
    metadata = attachment.metadata or {}
    request_id = metadata.get("capture_request_id")
    asked = (
        metadata.get("source") == "companion"
        and request_id
        and CompanionCaptureRequest.objects.filter(
            pk=request_id, created_by_id=getattr(user, "pk", None)
        ).exists()
    )
    if not asked or attachment.created_at < timezone.now() - COMPANION_RECEIPT_MAX_AGE:
        raise WalletError("invalid_receipt", status=422)
    with open_attachment(attachment) as handle:
        data = handle.read(MAX_RECEIPT_BYTES + 1)
    return SimpleUploadedFile(
        attachment.original_filename or "receipt", data, content_type=attachment.content_type
    )


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
    transfer = payload.get("transfer") or {}
    books.record_spend(
        kind=WalletSpend.Kind.SMS,
        relay_reference=_transfer_reference(key),
        amount=amount,
        description=SMS_SPEND_DESCRIPTION,
        happened_on=_happened_on((transfer.get("out") or {}).get("created_at")),
        user=user,
        main_balance=_decimal(payload.get("balance"), default=None),
    )
    return {
        "balance": payload.get("balance"),
        "sms": sms if isinstance(sms, dict) else None,
        "transfer": transfer,
        "replayed": bool(payload.get("replayed")),
    }


def allocate_to_vouchers(*, user, amount, idempotency_key=""):
    """Move money from the main wallet into the voucher balance, which every
    «كروت دفتر» card is paid from. Returns both balances and the transfer; a
    retry with the same key moves nothing again. In the books it moves money
    from «محفظة دفتر» into the «كروت دفتر» float (``apps.wallet.books``)."""
    installation, client = _relay()
    key = idempotency_key or f"vouchers-{uuid.uuid4()}"
    payload = _call(
        lambda: client.allocate_wallet_vouchers(
            access_token=installation.access_token,
            amount=amount,
            idempotency_key=key,
            requested_by=_requested_by(user),
            timeout=READ_TIMEOUT,
        )
    )
    transfer = payload.get("transfer") or {}
    books.record_spend(
        kind=WalletSpend.Kind.VOUCHERS,
        relay_reference=_transfer_reference(key),
        amount=amount,
        description=VOUCHERS_SPEND_DESCRIPTION,
        happened_on=_happened_on((transfer.get("out") or {}).get("created_at")),
        user=user,
        main_balance=_decimal(payload.get("balance"), default=None),
    )
    return {
        "balance": payload.get("balance"),
        "vouchers": _vouchers_block(payload.get("vouchers")),
        "transfer": transfer,
        "replayed": bool(payload.get("replayed")),
    }


def _transfer_reference(key):
    """The relay's own reference for a transfer made under ``key`` — the one its
    statement prints, and the one both of its entries carry."""
    return f"transfer:{key}"


def _happened_on(value):
    """The business day a relay movement happened, or today when it does not say."""
    return timezone.localdate(_instant(value) or timezone.now())


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
    entry = payload.get("entry") or {}
    _book_plan(plan, payload.get("plan") or {}, entry, key=key, user=user, balance=payload.get("balance"))
    return {
        "plan": payload.get("plan") or {},
        "balance": payload.get("balance"),
        "entry": entry,
        "replayed": bool(payload.get("replayed")),
    }


def _book_plan(plan, bought, entry, *, key, user, balance):
    """Book a plan paid from the wallet as the expense it is.

    The price is the relay's charge (``entry.amount``, negative): a relay answer
    without it cannot be booked from here, and is left to the owner.
    """
    charged = _decimal(entry.get("amount"), default=None)
    if charged is None or charged == 0:
        logger.warning("plan purchase %s answered without its charge; not booked", key)
        return
    description = str(entry.get("description") or "").strip()
    if not description:
        until = _instant(bought.get("until"))
        title = PLAN_TITLES.get(plan, plan)
        description = f"اشتراك {title}" + (
            f" حتى {timezone.localdate(until):%Y-%m-%d}" if until else ""
        )
    books.record_spend(
        kind=WalletSpend.Kind.PLAN,
        relay_reference=f"plan:{key}",
        amount=abs(charged),
        description=description,
        happened_on=_happened_on(entry.get("created_at")),
        user=user,
        main_balance=_decimal(balance, default=None),
    )


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
    """Catch payments nobody was watching, and bookings that failed. Asks the
    relay only when the shop has a top-up that could still change."""
    since = timezone.now() - SYNC_LOOKBACK
    open_topups = WalletTopUp.objects.filter(
        status__in=WalletTopUp.OPEN_STATUSES, relay_created_at__gte=since
    )
    # Retried for as long as the relay is asked about open ones: past that the
    # top-up shows its expense_error in the app and the owner records it.
    for topup in books.owed_topups(since=since).only("pk"):
        books.book_topup(topup.pk)
    for spend in books.owed_spends(since=since).only("pk"):
        books.book_spend(spend.pk)
    if not open_topups.exists():
        return {"asked_relay": False, "refreshed": 0}
    try:
        result = list_topups(limit=PAGE_LIMIT)
    except WalletError as error:
        logger.info("wallet sync skipped: %s", error.code)
        return {"asked_relay": True, "refreshed": 0, "error": error.code}
    return {"asked_relay": True, "refreshed": len(result["topups"])}
