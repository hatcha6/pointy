"""The Moamalat merchant portal API, as far as this shop needs it.

Read-only by construction: login, the merchant list, and the transaction list.
Nothing here can create or move anything on Moamalat's side. Shapes are in
``tools/moamalat-capture/API_CONTRACT.md``.

Every answer is classified the way the relay classifies it
(``relay/internal/moamalat/client.go``): a token is dead only on
``401 + {"oprationstate": "6"}``. A Cloudflare page, a timeout or a bare 401
says nothing about the token.
"""

from __future__ import annotations

import base64
import json
import logging
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation

import requests
from django.conf import settings

from apps.core.timeutils import business_timezone

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "https://merchant.moamalat.net/api"
#: Not a per-user secret: the portal's static client key, sent on login.
PUBLIC_KEY = "BecomITPementKey"
CLIENT_VERSION = "1.1.0"
REQUEST_TIMEOUT = 15
#: Pages hold 10 rows; a sweep never reads more than this many.
MAX_PAGES = 30

ALIVE = "alive"
DEAD = "dead"
TRANSIENT = "transient"


class PortalError(Exception):
    """A call the portal did not answer usefully. ``outcome`` says what it
    means for the token."""

    def __init__(self, message, *, outcome=TRANSIENT, status=0, retry_after=None, user_message=""):
        super().__init__(message)
        self.outcome = outcome
        self.status = status
        self.retry_after = retry_after
        # The portal's own words (Arabic), safe to show the supervisor.
        self.user_message = user_message


@dataclass
class Merchant:
    mid: str
    name: str
    owner: bool


@dataclass
class Transaction:
    rrn: str
    terminal_id: str
    amount: Decimal
    transaction_at: datetime
    processing_date: date | None
    settlement_amount: Decimal | None
    transaction_type: str
    card_mask: str


@dataclass
class TransactionPage:
    rows: list[Transaction] = field(default_factory=list)
    pages: int = 1
    total: int = 0


def base_url() -> str:
    return (getattr(settings, "POINTY_MOAMALAT_BASE_URL", "") or DEFAULT_BASE_URL).rstrip("/")


def _operation_state(body) -> str | None:
    if not isinstance(body, dict):
        return None
    state = body.get("oprationstate")
    if state is None and isinstance(body.get("data"), dict):
        state = body["data"].get("oprationstate")
    return None if state is None else str(state).strip()


def _retry_after(response) -> timedelta | None:
    value = (response.headers.get("Retry-After") or "").strip()
    if value.isdigit() and int(value) > 0:
        return timedelta(seconds=int(value))
    return None


def _call(method, path, *, token=None, body=None, params=None, session=None):
    """One call; returns the parsed JSON body of an accepted answer, or raises
    :class:`PortalError` saying what the failure means for the token."""
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    http = session or requests
    try:
        response = http.request(
            method,
            base_url() + path,
            headers=headers,
            json=body,
            params=params,
            timeout=REQUEST_TIMEOUT,
        )
    except requests.Timeout as exc:
        raise PortalError("timeout") from exc
    except requests.RequestException as exc:
        # Never the URL or headers: the token travels in them.
        raise PortalError(f"network: {type(exc).__name__}") from exc
    try:
        parsed = response.json()
    except ValueError:
        parsed = None
    state = _operation_state(parsed)
    message = parsed.get("msg", "") if isinstance(parsed, dict) else ""
    if response.status_code == 401 and state == "6":
        raise PortalError("401 oprationstate 6", outcome=DEAD, status=401, user_message=str(message or ""))
    if response.status_code == 429:
        raise PortalError("429", status=429, retry_after=_retry_after(response))
    if parsed is None:
        # Cloudflare pages are HTML whatever their status.
        raise PortalError(f"{response.status_code} non-JSON", status=response.status_code)
    if 200 <= response.status_code < 300 and state != "6":
        return parsed
    raise PortalError(
        f"{response.status_code} oprationstate {state!r}",
        status=response.status_code,
        user_message=str(message or ""),
    )


def _unwrap(body) -> dict:
    if isinstance(body, dict) and isinstance(body.get("data"), dict):
        return body["data"]
    return body if isinstance(body, dict) else {}


def _find_jwt(value) -> str | None:
    stack = [value]
    while stack:
        current = stack.pop()
        if isinstance(current, str) and current.count(".") == 2:
            head = current.split(".", 1)[0]
            try:
                decoded = base64.urlsafe_b64decode(head + "=" * (-len(head) % 4))
            except (ValueError, TypeError):
                continue
            if b'"alg"' in decoded:
                return current
        elif isinstance(current, dict):
            stack.extend(current.values())
        elif isinstance(current, list):
            stack.extend(current)
    return None


# -- login ------------------------------------------------------------------


def start_login(username: str, password: str) -> tuple[str, str]:
    """Step 1: username + password. Moamalat texts an OTP to the merchant's
    phone and answers a short-lived challenge token. Returns (challenge, msg).

    The password goes straight to Moamalat and is never kept.
    """
    body = _unwrap(
        _call(
            "POST",
            "/login-user",
            body={
                "username": username,
                "password": password,
                "publickey": PUBLIC_KEY,
                "version": CLIENT_VERSION,
                "os": "web",
            },
        )
    )
    challenge = body.get("token")
    if not isinstance(challenge, str) or not challenge:
        raise PortalError("login gave no challenge", outcome=TRANSIENT, user_message=str(body.get("msg") or ""))
    return challenge, str(body.get("msg") or "")


def verify_login(challenge: str, code: str) -> str:
    """Step 2: the OTP. Returns the bearer token."""
    body = _call(
        "POST",
        "/verify-code",
        body={"code": code, "token": challenge, "publickey": PUBLIC_KEY},
    )
    bearer = _find_jwt(body) or _unwrap(body).get("token")
    if not isinstance(bearer, str) or bearer.count(".") != 2:
        raise PortalError("verify gave no bearer", user_message=str(_unwrap(body).get("msg") or ""))
    return bearer


# -- logged in ----------------------------------------------------------------


def poke(token: str) -> None:
    """The cheapest authenticated call: resets the token's window. Raises
    :class:`PortalError` unless the token was accepted."""
    _call("GET", "/get-merchant/dest", token=token)


def merchants(token: str) -> list[Merchant]:
    body = _unwrap(_call("GET", "/get-merchant/dest", token=token))
    rows = body.get("listOfMerchant") or []
    found = []
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict):
            continue
        mid = str(row.get("outlet_number") or "").strip()
        if mid:
            found.append(
                Merchant(
                    mid=mid,
                    name=str(row.get("english_name") or "").strip(),
                    owner=bool(row.get("owner")),
                )
            )
    return found


def _decimal(value) -> Decimal | None:
    if value in (None, ""):
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def _parse_transaction(row) -> Transaction | None:
    if not isinstance(row, dict):
        return None
    rrn = str(row.get("REFERENCE_NUMBER") or "").strip()
    amount = _decimal(row.get("TRANSACTION_AMOUNT"))
    raw_at = str(row.get("TRANSACTION_DATE") or "").strip()
    if not rrn or amount is None or not raw_at:
        return None
    try:
        # Local terminal time with no zone: the shop's business timezone.
        naive = datetime.strptime(raw_at[:19], "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    processing = None
    raw_processing = str(row.get("PROCESSING_DATE") or "").strip()
    if raw_processing:
        try:
            processing = date.fromisoformat(raw_processing[:10])
        except ValueError:
            processing = None
    return Transaction(
        rrn=rrn[:32],
        terminal_id=str(row.get("TERMINAL_ID") or "").strip().upper()[:32],
        amount=amount,
        transaction_at=naive.replace(tzinfo=business_timezone()),
        processing_date=processing,
        settlement_amount=_decimal(row.get("ACQUIRER_SETTLEMENT_AMOUNT")),
        transaction_type=str(row.get("transaction_type") or "").strip()[:16],
        card_mask=str(row.get("CARD_NUMBER") or "").strip()[:32],
    )


def transactions(token: str, mid: str, *, processed_from: date, processed_to: date, page: int = 1, ref_number: str = "") -> TransactionPage:
    """One page of the transaction list.

    The list's date filter is the PROCESSING (settlement) date, not the swipe
    date (``API_CONTRACT.md`` §2), so a window meant to catch a sale rung up a
    minute ago has to reach forward to the day it will settle.
    """
    body = {
        "out_let": mid,
        "fromdate_proc": processed_from.isoformat(),
        "todate_proc": processed_to.isoformat(),
        "card_type": "local",
    }
    if ref_number:
        body["ref_number"] = ref_number
    answer = _unwrap(_call("POST", "/transformerch", token=token, body=body, params={"page": page}))
    rows = answer.get("listOfTrans") or []
    parsed = [tx for tx in (_parse_transaction(row) for row in rows if isinstance(rows, list)) if tx]
    try:
        pages = max(1, int(answer.get("pages") or 1))
    except (TypeError, ValueError):
        pages = 1
    try:
        total = int(answer.get("total") or len(parsed))
    except (TypeError, ValueError):
        total = len(parsed)
    return TransactionPage(rows=parsed, pages=min(pages, MAX_PAGES), total=total)


def describe(exc: PortalError) -> str:
    """A token-free one-liner for logs and the settings screen."""
    return json.dumps(str(exc))[1:-1][:300]
