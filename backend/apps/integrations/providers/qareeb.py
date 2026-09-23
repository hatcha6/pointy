"""Qareeb — a JSON API behind a Flutter agency app, driven as that app drives it.

There is no published API. Everything below was read off the agency's own
iPhone app, captured 2026-09-23 (``tools/qareeb-capture``; the redacted
contract is ``tools/qareeb-capture/API_CONTRACT.md``). What that capture
established, and what this driver therefore must not assume:

* **JWT bearer, and a long one.** ``POST /api/login/`` answers an ``access``
  token good for 28 days and a ``refresh`` good for 100 (SimpleJWT claims).
  The access token is kept among the account's encrypted secrets rather than in
  a cache, because it outlives any cache and a login is not free: see the next
  point.
* **A new device is refused a password login.** From a machine Qareeb has not
  seen, the right password answers 400 "جهاز جديد: الرجاء تسجيل الدخول بكلمة
  مرور مؤقتة (OTP)". The way in is a one-time code texted to the agency's
  phone, and asking for one needs the text of a captcha picture read by a
  person. So connecting Pointy is a step in Shop Settings, done once, and
  every login after it is an ordinary password login from a device Qareeb
  knows. The device is recognised by the identity headers the app sends —
  ``x-device-uuid`` and ``identifier`` — which this driver mints once per
  account and never changes.
* **Firebase App Check guards the app, not the API — today.** The app refuses
  to log in when its own attestation fails, but not one request to
  ``api.qareb.ly`` in the capture carried an App Check token: no
  ``X-Firebase-AppCheck`` header, on login, on the one-time code, or on any
  logged-in call. The day Qareeb starts demanding one, nothing outside a real
  phone can produce it. That failure is classified as
  ``attestation_required`` — never as a wrong password — so it is diagnosed in
  one look instead of an afternoon. See :func:`_demands_attestation`.
* **The basket is shared server-side state.** ``/api/v1/cart/`` is one cart per
  agency account: the owner's phone and every till see the same one. A
  checkout buys *whatever is in it*. So a purchase empties it of anything that
  is not ours, puts exactly one card in, reads it back and only then checks
  out — and two tills of one shop take turns (:func:`_cart_lock`).
* **Checkout echoes a hash from a live read of the basket.** Never computed,
  never reused: it is Qareeb's own proof that what is bought is what was read.
* **Nothing is idempotent.** ``order_reference`` identifies a purchase after
  the fact, not before. A replayed checkout is a second real card. The
  at-most-once guard in :mod:`apps.integrations.recharge` is the protection;
  this driver's job is to be honest about which of three outcomes happened.
* **Every price is dinars.** A 100-dollar PSN card is priced 977.000 and costs
  the float 947.69 — ``amount`` is the face in the card's own currency and is
  a label, never arithmetic.
* The purchase PIN is a per-account toggle in Qareeb's settings; the basket
  says whether this account wants it (``is_pin_required``), and only then is
  the stored one sent.
"""

from __future__ import annotations

import base64
import json
import logging
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone as utc_timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from urllib.parse import quote, urljoin

import requests
from django.core.cache import cache
from django.db import transaction

from apps.core.timeutils import business_timezone

from .. import connection_pool
from ..catalog import FIELD_PIN
from ..telemetry import STEP_FORM, STEP_LOGIN, STEP_PARSE, STEP_SUBMIT
from .base import (
    ERROR_ATTESTATION_REQUIRED,
    ERROR_BUSY,
    ERROR_DEVICE_VERIFICATION,
    ERROR_INDETERMINATE,
    ERROR_INSUFFICIENT_FLOAT,
    ERROR_NOT_CONFIGURED,
    ERROR_OUT_OF_STOCK,
    ERROR_PIN_REQUIRED,
    ERROR_PROFILE_MISMATCH,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAUTHORIZED,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    ERROR_VERIFICATION_REJECTED,
    HISTORY_PURCHASES,
    HistoryResult,
    IntegrationProvider,
    OptionQuote,
    ProbeResult,
    ProfilesResult,
    ProviderProfile,
    PurchaseEntry,
    RechargeResult,
    VerificationChallenge,
    VerificationResult,
    VoucherBrand,
    VoucherCatalogResult,
    VoucherItem,
    register,
)

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_SECONDS = 15
#: The money call gets more patience than a read. A checkout that times out is
#: an outcome nobody knows — it costs a human a look at the provider's log —
#: so it is worth waiting for an answer rather than abandoning one.
CHECKOUT_TIMEOUT_SECONDS = 30

LOGIN_PATH = "/api/login/"
CAPTCHA_PATH = "/api/v2/otp/step1"
SEND_CODE_PATH = "/api/v2/otp/"
VERIFY_CODE_PATH = "/api/verify_otp/"
ACCOUNT_PATH = "/api/store/v1/account_info/"
CATALOG_PATH = "/api/store/v2/product_list_detailed/in_stock/"
BRAND_PATH = "/api/store/v1/get_product_price/{code}/"
CART_PATH = "/api/v1/cart/"
CHECKOUT_PATH = "/api/v1/cart/checkout/"
VOUCHERS_PATH = "/api/store/v1/vouchers_history/"
PROFILES_PATH = "/api/get_available_profiles/v1/"

# --- where this driver keeps its own state on the account -------------------
#: Encrypted, beside the password: a bearer token is a credential.
SECRET_ACCESS = "access_token"
SECRET_REFRESH = "refresh_token"
#: The one-time-code session between "text me a code" and "here it is".
SECRET_VERIFICATION = "verification_session"
#: Not secret, but never to change once minted: they are what Qareeb
#: recognises this Pointy by. A new value is a new device, and a new device
#: cannot log in without the owner's phone.
CONFIG_DEVICE_UUID = "device_uuid"
CONFIG_DEVICE_IDENTIFIER = "device_identifier"
#: The profile the owner chose for Pointy to buy as, and its name for display.
#: Blank means "whichever the login is acting as", which is what the app does.
CONFIG_PROFILE_ID = "profile_id"
CONFIG_PROFILE_NAME = "profile_name"

# --- the app's own request shape ---------------------------------------------
#: Reproduced value for value from the capture (2026-09-23, the agency's own
#: iPhone on app 1.1.8.13). The API keys nothing on these today beyond the
#: device identity, but a request that looks exactly like the app's is the one
#: least likely to be treated as something else — so nothing here is ours,
#: not even the model name.
APP_HEADERS = {
    "user-agent": "Dart/3.6 (dart:io)",
    "accept": "application/json",
    "content-type": "application/json",
    "channel": "iPhone",
    "x-app-type": "mobile",
    "version": "1.1.8.13",
    "x-os-version": "27.0",
    "x-device-model": "iPhone",
}

#: Categories that are not cards. International transfers send money to a
#: recipient the till never names — a Vodafone Cash wallet, a Sudanese bank
#: account — so "tap it and hand over a code" would buy something nobody can
#: receive. Matched on the provider's own Arabic label.
EXCLUDED_CATEGORY_MARKERS = ("حوالات",)

#: Account-wide voucher log, newest first, fifteen to a page in the capture.
HISTORY_MAX_PAGES = 6

#: A purchase can only happen while the basket is ours. Long enough for the
#: slowest checkout we are prepared to wait for, and no longer: a process that
#: dies holding it must not stop the shop selling for more than a minute.
CART_LOCK_SECONDS = CHECKOUT_TIMEOUT_SECONDS + 30
CART_LOCK_WAIT_SECONDS = 20.0

BEGINNING_OF_TIME = datetime(1970, 1, 1, tzinfo=utc_timezone.utc)

_CENT = Decimal("0.01")


def _new_session(account):
    """A session of this driver's own, on the host's shared connection pool."""
    return connection_pool.warm(requests.Session(), account.resolved_base_url())


@register("qareeb")
class QareebProvider(IntegrationProvider):
    #: One feed, account-wide: every card this agency bought, newest first.
    #: Nothing is kept per subscriber — a card off a shelf has none.
    history_kinds = (HISTORY_PURCHASES,)

    def __init__(self, account):
        super().__init__(account)
        self._session: requests.Session | None = None
        #: False on a driver running in a worker thread. A login writes the
        #: new token to the database, and a worker's writes land in its own
        #: transaction (see ``providers.base.in_parallel``) — so a worker that
        #: finds its token dead reports that and leaves the login to the
        #: thread that owns the request.
        self.may_login = True

    # --- configuration -----------------------------------------------------
    @property
    def _timeout(self) -> int:
        raw = (self.account.config or {}).get("timeout_seconds")
        try:
            value = int(raw)
        except (TypeError, ValueError):
            return DEFAULT_TIMEOUT_SECONDS
        return value if value > 0 else DEFAULT_TIMEOUT_SECONDS

    def _url(self, path: str) -> str:
        return f"{self.account.resolved_base_url()}{path}"

    def _http(self) -> requests.Session:
        if self._session is None:
            self._session = _new_session(self.account)
        return self._session

    def _device_ids(self) -> tuple[str, str]:
        """``(x-device-uuid, identifier)``, minted once per account and kept.

        Minted under a row lock so two processes meeting a fresh account at
        once cannot each mint their own and leave one of them a stranger to
        Qareeb for ever after.
        """
        config = self.account.config or {}
        device_uuid = config.get(CONFIG_DEVICE_UUID)
        identifier = config.get(CONFIG_DEVICE_IDENTIFIER)
        if device_uuid and identifier:
            return device_uuid, identifier
        if not self.account.pk:
            return str(uuid.uuid4()), str(uuid.uuid4()).upper()

        from ..models import IntegrationAccount

        with transaction.atomic():
            row = IntegrationAccount.objects.select_for_update().get(pk=self.account.pk)
            stored = dict(row.config or {})
            stored.setdefault(CONFIG_DEVICE_UUID, str(uuid.uuid4()))
            stored.setdefault(CONFIG_DEVICE_IDENTIFIER, str(uuid.uuid4()).upper())
            if stored != row.config:
                # ``update()``, not ``save()``: the device identity is not part
                # of the settings payload the tills revalidate on.
                IntegrationAccount.objects.filter(pk=row.pk).update(config=stored)
        self.account.config = stored
        return stored[CONFIG_DEVICE_UUID], stored[CONFIG_DEVICE_IDENTIFIER]

    def _headers(self, token: str = "") -> dict:
        device_uuid, identifier = self._device_ids()
        headers = {
            **APP_HEADERS,
            "x-device-uuid": device_uuid,
            "identifier": identifier,
        }
        if token:
            headers["authorization"] = f"Bearer {token}"
        return headers

    # --- the stored login --------------------------------------------------
    def _store_secrets(self, **values) -> None:
        """Write driver-owned secrets without touching anything else.

        Under a row lock, re-reading the stored blob first, so a login that
        lands at the same moment the owner changes the password cannot put
        the old password back.
        """
        for key, value in values.items():
            self.account.set_secret(key, value)
        if not self.account.pk:
            return
        from ..models import IntegrationAccount

        with transaction.atomic():
            row = IntegrationAccount.objects.select_for_update().get(pk=self.account.pk)
            for key, value in values.items():
                row.set_secret(key, value)
            IntegrationAccount.objects.filter(pk=row.pk).update(
                secrets_encrypted=row.secrets_encrypted
            )
        self.account.secrets_encrypted = row.secrets_encrypted

    def _stored_token(self) -> str:
        token = self.account.get_secret(SECRET_ACCESS)
        if token and _token_expired(token):
            return ""
        return token

    def _login(self) -> tuple[str, str, str]:
        """``(access_token, error_code, detail)`` — a fresh password login."""
        if not (self.account.username and self.account.password):
            return "", ERROR_NOT_CONFIGURED, "phone number and password are required"
        self._note(STEP_LOGIN)
        try:
            response = self._http().post(
                self._url(LOGIN_PATH),
                json={
                    "username": self.account.username,
                    "password": self.account.password,
                    # The app sends its Firebase Cloud Messaging token here so
                    # Qareeb can push to the phone. A till has nothing to push
                    # to; empty is the honest value.
                    "fcm_token": "",
                },
                headers=self._headers(),
                timeout=self._timeout,
            )
        except requests.RequestException as exc:
            return "", ERROR_UNREACHABLE, str(exc)

        self._observe(http_status=response.status_code)
        payload = _json(response)
        if _demands_attestation(response, payload):
            return "", ERROR_ATTESTATION_REQUIRED, _message(payload)
        if response.status_code >= 500:
            return "", ERROR_PROVIDER_ERROR, f"login answered {response.status_code}"
        if not isinstance(payload, dict):
            self._observe(shape_ok=False)
            return "", ERROR_UNEXPECTED, "login did not answer JSON"
        message = _message(payload)
        if response.status_code >= 400:
            if _is_new_device(message):
                return "", ERROR_DEVICE_VERIFICATION, message
            return "", ERROR_UNAUTHORIZED, message or "login rejected"
        access = _plain_str(payload.get("access"))
        if not access:
            self._observe(shape_ok=False)
            return "", ERROR_UNEXPECTED, "login answered without a token"
        self._store_secrets(
            **{SECRET_ACCESS: access, SECRET_REFRESH: _plain_str(payload.get("refresh"))}
        )
        return access, "", ""

    def _token(self) -> tuple[str, str, str]:
        token = self._stored_token()
        if token:
            return token, "", ""
        if not self.may_login:
            return "", ERROR_UNAUTHORIZED, "no live token on this thread"
        return self._login()

    def _authed(self, method: str, path: str, *, json_body=None, params=None, timeout=None):
        """One authenticated call, logging in again once if the token died.

        Returns ``(response, error_code, detail)``. A 401 is retried exactly
        once, after a fresh login: an expired token is an ordinary event every
        28 days, and a 401 means the request was refused before anything was
        done, so repeating it cannot double anything.
        """
        token, code, detail = self._token()
        if not token:
            return None, code, detail
        for attempt in range(2):
            try:
                response = self._http().request(
                    method,
                    self._url(path),
                    json=json_body,
                    params=params,
                    headers=self._headers(token),
                    timeout=timeout or self._timeout,
                )
            except requests.RequestException as exc:
                return None, ERROR_UNREACHABLE, str(exc)
            self._observe(http_status=response.status_code)
            payload = _json(response)
            if _demands_attestation(response, payload):
                return None, ERROR_ATTESTATION_REQUIRED, _message(payload)
            if response.status_code != 401:
                return response, "", ""
            if attempt or not self.may_login:
                return None, ERROR_UNAUTHORIZED, _message(payload) or "token refused"
            self._store_secrets(**{SECRET_ACCESS: ""})
            token, code, detail = self._login()
            if not token:
                return None, code, detail
        return None, ERROR_UNAUTHORIZED, "token refused"  # pragma: no cover

    # --- health --------------------------------------------------------------
    def probe(self) -> ProbeResult:
        response, code, detail = self._authed("GET", ACCOUNT_PATH)
        if response is None:
            return ProbeResult(ok=False, error_code=code, error_detail=detail)
        payload = _json(response)
        if response.status_code >= 400 or not isinstance(payload, dict):
            return ProbeResult(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR if response.status_code >= 400 else ERROR_UNEXPECTED,
                error_detail=_message(payload) or f"account answered {response.status_code}",
            )
        self._note(STEP_PARSE)
        result = payload.get("result")
        if not isinstance(result, dict):
            self._observe(shape_ok=False)
            return ProbeResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="no account in reply")
        balance = _decimal(result.get("balance"))
        mismatch = self._profile_mismatch()
        if mismatch is not None:
            # The float above is some other profile's wallet. Reporting it as
            # this shop's would be worse than reporting nothing.
            return ProbeResult(
                ok=False, error_code=ERROR_PROFILE_MISMATCH, error_detail=mismatch
            )
        return ProbeResult(
            ok=True,
            balance=_quantize(balance) if balance is not None else None,
            account_label=_plain_str(result.get("account_name")),
        )

    # --- which identity the login acts as ------------------------------------
    def profiles(self) -> ProfilesResult:
        response, code, detail = self._authed("GET", PROFILES_PATH)
        if response is None:
            return ProfilesResult(ok=False, error_code=code, error_detail=detail)
        payload = _json(response)
        rows = payload.get("available_profiles") if isinstance(payload, dict) else None
        if response.status_code >= 400 or not isinstance(rows, list):
            return ProfilesResult(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR if response.status_code >= 400 else ERROR_UNEXPECTED,
                error_detail=_message(payload) or f"profiles answered {response.status_code}",
            )
        profiles = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            profile_id = _plain_str(row.get("profile_id"))
            if not profile_id:
                continue
            kind = _plain_str(row.get("profile_type"))
            # The profile's own record sits under a key named for its kind:
            # {"profile_type": "store_employee", "store_employee": {"name": …}}.
            detail_row = row.get(kind) if isinstance(row.get(kind), dict) else {}
            profiles.append(
                ProviderProfile(
                    profile_id=profile_id,
                    name=_plain_str(detail_row.get("name")),
                    kind=kind,
                    is_current=_truthy(row.get("is_active")),
                )
            )
        return ProfilesResult(ok=True, profiles=tuple(profiles))

    def _chosen_profile(self) -> str:
        return _plain_str((self.account.config or {}).get(CONFIG_PROFILE_ID))

    def _profile_mismatch(self) -> str | None:
        """Why the login is not acting as the chosen profile, or ``None``.

        No choice is no constraint — the app itself sends ``profile: null``
        and buys as whatever the login is. An unreadable profile list is a
        mismatch: which wallet would pay cannot be proved.
        """
        chosen = self._chosen_profile()
        if not chosen:
            return None
        result = self.profiles()
        if not result.ok:
            return f"could not read profiles: {result.error_code}"
        known = {profile.profile_id: profile for profile in result.profiles}
        if chosen not in known:
            return "the chosen profile is no longer available to this login"
        if not known[chosen].is_current:
            return "the login is acting as another profile"
        return None

    def _balance(self) -> Decimal | None:
        """The float as it stands now, or ``None``. For after a purchase."""
        result = self.probe()
        return result.balance if result.ok else None

    # --- the shelf -----------------------------------------------------------
    def voucher_catalog(self) -> VoucherCatalogResult:
        response, code, detail = self._authed("GET", CATALOG_PATH)
        if response is None:
            return VoucherCatalogResult(ok=False, error_code=code, error_detail=detail)
        payload = _json(response)
        if response.status_code >= 400 or not isinstance(payload, dict):
            return VoucherCatalogResult(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR if response.status_code >= 400 else ERROR_UNEXPECTED,
                error_detail=_message(payload) or f"catalog answered {response.status_code}",
            )
        self._note(STEP_PARSE)
        categories = payload.get("result")
        if not isinstance(categories, list):
            self._observe(shape_ok=False)
            return VoucherCatalogResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="no categories in reply"
            )
        brands = []
        seen = set()
        for category in categories:
            if not isinstance(category, dict):
                continue
            label = _plain_str(category.get("category_name"))
            if any(marker in label for marker in EXCLUDED_CATEGORY_MARKERS):
                continue
            # Only a category the app draws open carries its items inline;
            # the rest list their brands and leave the items one call away.
            # Taken from the flag where there is one, from the data otherwise.
            spelled_out = category.get("display_product")
            for raw in category.get("data") or ():
                brand = _parse_brand(raw, category=label)
                if brand is None or brand.code in seen:
                    continue
                seen.add(brand.code)
                known = bool(spelled_out) if spelled_out is not None else bool(brand.items)
                brands.append(_with_items_known(brand, known))
        return VoucherCatalogResult(ok=True, brands=tuple(brands))

    def voucher_brand(self, brand_code: str) -> VoucherCatalogResult:
        code = (brand_code or "").strip()
        if not code:
            return VoucherCatalogResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="no brand")
        response, error, detail = self._authed(
            "GET", BRAND_PATH.format(code=quote(code, safe=""))
        )
        if response is None:
            return VoucherCatalogResult(ok=False, error_code=error, error_detail=detail)
        payload = _json(response)
        if response.status_code >= 400 or not isinstance(payload, dict):
            return VoucherCatalogResult(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR if response.status_code >= 400 else ERROR_UNEXPECTED,
                error_detail=_message(payload) or f"brand answered {response.status_code}",
            )
        self._note(STEP_PARSE)
        brand = _parse_brand(payload.get("result"), category="")
        if brand is None:
            self._observe(shape_ok=False)
            return VoucherCatalogResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="no brand in reply"
            )
        return VoucherCatalogResult(ok=True, brands=(_with_items_known(brand, True),))

    # --- offline arithmetic ------------------------------------------------
    def quote(self, option_code: str) -> OptionQuote | None:
        """The cost of a card from the shelf as last read. No network.

        A read of our own mirror, not arithmetic — but it is what makes the
        checkout's cost the server's figure rather than something a till
        asserted, which is the whole point of ``quote``.
        """
        from ..models import IntegrationVoucher

        if not self.account.pk:
            return None
        cost = (
            IntegrationVoucher.objects.filter(
                account_id=self.account.pk, code=(option_code or "").strip()
            )
            .values_list("cost", flat=True)
            .first()
        )
        return None if cost is None else OptionQuote(cost=cost)

    # --- buying one card -----------------------------------------------------
    def recharge(self, card_no: str, option_code: str, *, expected_cost=None):
        """Buy one card off the shelf. Spends the agency float.

        ``card_no`` is ignored: a card belongs to nobody until it is sold.
        Everything before the checkout POST is preparation and fails
        *definitely* — nothing has been bought, the row may be tried again.
        From the checkout POST on, an answer that does not say what happened is
        ``indeterminate``, and nothing may send it again.
        """
        code = (option_code or "").strip()
        if not code:
            return RechargeResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="no card")
        with _cart_lock(self.account) as held:
            if not held:
                return RechargeResult(
                    ok=False,
                    error_code=ERROR_BUSY,
                    error_detail="another sale is using the provider basket",
                )
            return self._buy(code, expected_cost)

    def _buy(self, code: str, expected_cost) -> RechargeResult:
        self._note(STEP_FORM)
        # 1. One of ours in the basket. The quantity is absolute, not added.
        refusal = self._set_quantity(code, 1)
        if refusal is not None:
            return refusal

        # 2. Read it back until it holds exactly that and nothing else. The
        #    basket is shared with the owner's phone: anything else in it would
        #    be bought by our checkout.
        cart, refusal = self._settled_cart(code)
        if refusal is not None:
            return refusal
        ours = cart.items[0]

        # 3. The price the customer paid against is the price we pay.
        if expected_cost is not None and ours.cost is not None:
            if _quantize(ours.cost) != _quantize(Decimal(expected_cost)):
                self._set_quantity(code, 0)
                return RechargeResult(
                    ok=False,
                    error_code=ERROR_PROVIDER_ERROR,
                    error_detail=f"cost moved: quoted {expected_cost}, now {ours.cost}",
                )

        profile, refusal = self._checkout_profile(cart)
        if refusal is not None:
            self._set_quantity(code, 0)
            return refusal

        pin = None
        if cart.pin_required:
            pin = self.account.get_secret(FIELD_PIN) or None
            if not pin:
                self._set_quantity(code, 0)
                return RechargeResult(
                    ok=False,
                    error_code=ERROR_PIN_REQUIRED,
                    error_detail="this account requires its purchase PIN",
                )

        # 4. The money. Recorded as the step BEFORE the request, so a process
        #    that dies mid-call leaves telemetry saying the write may be out.
        self._note(STEP_SUBMIT)
        token, error, detail = self._token()
        if not token:
            self._set_quantity(code, 0)
            return RechargeResult(ok=False, error_code=error, error_detail=detail)
        try:
            response = self._http().post(
                self._url(CHECKOUT_PATH),
                json={"hash": cart.hash, "pin": pin, "profile": profile},
                headers=self._headers(token),
                timeout=CHECKOUT_TIMEOUT_SECONDS,
            )
        except requests.RequestException as exc:
            if _never_sent(exc):
                # The connection never opened, so the request never left.
                return RechargeResult(
                    ok=False, error_code=ERROR_UNREACHABLE, error_detail=str(exc)
                )
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail=f"checkout may have gone through: {exc}",
            )
        return self._checkout_outcome(code, response)

    def _checkout_outcome(self, code: str, response) -> RechargeResult:
        self._observe(http_status=response.status_code)
        payload = _json(response)
        status = response.status_code
        if status >= 500:
            # A server error mid-checkout may have committed the order first.
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail=f"checkout answered {status}",
            )
        if status >= 400:
            # Refused before it was performed: validation, a stale hash, the
            # float, the PIN. Take our card back out so the basket is clean.
            message = _message(payload)
            if _demands_attestation(response, payload):
                return RechargeResult(
                    ok=False, error_code=ERROR_ATTESTATION_REQUIRED, error_detail=message
                )
            self._set_quantity(code, 0)
            return RechargeResult(
                ok=False,
                error_code=_classify_refusal(message, status),
                error_detail=message or f"checkout answered {status}",
            )
        if not isinstance(payload, dict):
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                error_detail="checkout did not answer JSON",
            )

        self._note(STEP_PARSE)
        order_reference = _plain_str(payload.get("order_reference"))
        cards = [row for row in payload.get("result") or () if isinstance(row, dict)]
        self._observe(provider_reference=order_reference)
        if not _truthy(payload.get("status")) or not cards:
            # Territory the capture never showed. Checkout said 2xx, so an
            # order may exist: a human looks before anything is tried again.
            self._observe(shape_ok=False)
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                reference=order_reference,
                error_detail=_message(payload) or "checkout answered without a card",
            )

        card = cards[0]
        receipt = _receipt_for(card, order_reference=order_reference)
        if not receipt["printed"].get("code"):
            self._observe(shape_ok=False)
            return RechargeResult(
                ok=False,
                indeterminate=True,
                error_code=ERROR_INDETERMINATE,
                reference=_plain_str(card.get("id")) or order_reference,
                receipt=receipt,
                error_detail="card bought but its code was not in the reply",
            )
        return RechargeResult(
            ok=True,
            # The card's own id: it is what the voucher log calls it, so
            # reconciliation can find exactly this card again.
            reference=_plain_str(card.get("id")) or order_reference,
            balance_after=self._balance(),
            receipt=receipt,
        )

    def _checkout_profile(self, cart):
        """``(profile, refusal)`` — what checkout's ``profile`` field carries.

        ``None`` when the login already acts as the chosen profile (or none was
        chosen): exactly what the app sends. The chosen id when it differs and
        the basket says this account may pay from another profile at checkout
        (``is_quick_switch_enabled``). Otherwise a definite refusal: buying
        from whichever wallet the login happens to be on is not ours to do.
        """
        chosen = self._chosen_profile()
        if not chosen:
            return None, None
        mismatch = self._profile_mismatch()
        if mismatch is None:
            return None, None
        if cart.quick_switch and "no longer available" not in mismatch:
            return chosen, None
        return None, RechargeResult(
            ok=False, error_code=ERROR_PROFILE_MISMATCH, error_detail=mismatch
        )

    def _set_quantity(self, code: str, quantity: int) -> RechargeResult | None:
        """``None`` on success, else a definite refusal. Never the money."""
        response, error, detail = self._authed(
            "POST", CART_PATH, json_body={"product": code, "quantity": quantity}
        )
        if response is None:
            return RechargeResult(ok=False, error_code=error, error_detail=detail)
        payload = _json(response)
        body = payload if isinstance(payload, dict) else {}
        if response.status_code >= 400 or not _truthy(body.get("status", True)):
            message = _message(payload)
            return RechargeResult(
                ok=False,
                error_code=_classify_refusal(message, response.status_code),
                error_detail=message or f"basket answered {response.status_code}",
            )
        return None

    def _read_cart(self):
        response, error, detail = self._authed("GET", CART_PATH)
        if response is None:
            return None, RechargeResult(ok=False, error_code=error, error_detail=detail)
        payload = _json(response)
        cart = _parse_cart(payload) if response.status_code < 400 else None
        if cart is None:
            self._observe(shape_ok=False)
            return None, RechargeResult(
                ok=False,
                error_code=ERROR_UNEXPECTED,
                error_detail=_message(payload) or "basket did not read back",
            )
        return cart, None

    def _settled_cart(self, code: str):
        """The basket holding exactly one of ``code``, or a definite refusal."""
        for _attempt in range(3):
            cart, refusal = self._read_cart()
            if refusal is not None:
                return None, refusal
            foreign = [item for item in cart.items if item.product_id != code]
            ours = [item for item in cart.items if item.product_id == code]
            if not foreign and len(ours) == 1 and ours[0].quantity == 1:
                return cart, None
            for item in foreign:
                refusal = self._set_quantity(item.product_id, 0)
                if refusal is not None:
                    return None, refusal
            if not ours or ours[0].quantity != 1:
                refusal = self._set_quantity(code, 1)
                if refusal is not None:
                    return None, refusal
        self._set_quantity(code, 0)
        return None, RechargeResult(
            ok=False,
            error_code=ERROR_BUSY,
            error_detail="the provider basket kept changing under us",
        )

    # --- history -------------------------------------------------------------
    def purchase_history(self, card_no: str, *, limit: int = 10, offset: int = 0):
        """Every card this agency bought, newest first. ``card_no`` is ignored.

        The log is account-wide and newest first, so pages read from the top
        are complete back to their oldest row — which is what lets
        reconciliation read absence as proof. A page boundary can split two
        cards bought in the same instant, so the claim starts just after the
        oldest row rather than at it.
        """
        wanted = max(0, offset) + max(1, limit)
        entries: list[PurchaseEntry] = []
        total = 0
        reached_end = False
        page = 1
        while len(entries) < wanted and page <= HISTORY_MAX_PAGES:
            response, code, detail = self._authed(
                "GET", VOUCHERS_PATH, params={"page": page} if page > 1 else None
            )
            if response is None:
                return HistoryResult(ok=False, error_code=code, error_detail=detail)
            payload = _json(response)
            if response.status_code >= 400 or not isinstance(payload, dict):
                return HistoryResult(
                    ok=False,
                    error_code=ERROR_PROVIDER_ERROR if response.status_code >= 400 else ERROR_UNEXPECTED,
                    error_detail=_message(payload) or f"history answered {response.status_code}",
                )
            rows = payload.get("results")
            if not isinstance(rows, list):
                self._observe(shape_ok=False)
                return HistoryResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="no results")
            total = _int(payload.get("total_results")) or total
            entries.extend(
                entry
                for entry in (self._history_entry(row) for row in rows)
                if entry is not None
            )
            total_pages = _int(payload.get("total_pages")) or page
            if not rows or page >= total_pages:
                reached_end = True
                break
            page += 1

        dated = [entry.at for entry in entries if entry.at is not None]
        if reached_end:
            complete_since = BEGINNING_OF_TIME
        elif dated:
            complete_since = min(dated).replace(microsecond=0) + _ONE_SECOND
        else:
            complete_since = None
        return HistoryResult(
            ok=True,
            total=total or len(entries),
            purchases=tuple(entries[offset:offset + limit]),
            complete_since=complete_since,
        )

    def _history_entry(self, row) -> PurchaseEntry | None:
        if not isinstance(row, dict):
            return None
        status = _plain_str(row.get("status"))
        if status and status != "sent":
            return None
        return PurchaseEntry(
            reference=_plain_str(row.get("voucher_id")),
            cost=_quantize(_decimal(row.get("cost"))),
            at=_local_datetime(row.get("purchase_date")),
            package_id=_plain_str(row.get("mno_type__code")),
            package_name=" ".join(
                part
                for part in (
                    _plain_str(row.get("mno_type__name")),
                    _plain_str(row.get("product")),
                )
                if part
            ),
            # Deliberately blank: the log names the buyer by phone number,
            # and a PurchaseEntry is shown and exported. Who bought it only
            # decides whether it was this login, below.
            operator_name="",
            is_ours=_same_phone(row.get("purchase_user"), self.account.username),
            printed=_printed_fields(row),
        )

    # --- confirming this device ------------------------------------------------
    def start_verification(self) -> VerificationChallenge:
        try:
            response = self._http().get(
                self._url(CAPTCHA_PATH), headers=self._headers(), timeout=self._timeout
            )
        except requests.RequestException as exc:
            return VerificationChallenge(ok=False, error_code=ERROR_UNREACHABLE, error_detail=str(exc))
        payload = _json(response)
        if _demands_attestation(response, payload):
            return VerificationChallenge(
                ok=False, error_code=ERROR_ATTESTATION_REQUIRED, error_detail=_message(payload)
            )
        field = (payload or {}).get("field") if isinstance(payload, dict) else None
        if response.status_code >= 400 or not isinstance(field, dict):
            return VerificationChallenge(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR if response.status_code >= 400 else ERROR_UNEXPECTED,
                error_detail=_message(payload) or "no captcha in reply",
            )
        challenge_ref = _plain_str(field.get("hashkey"))
        image_url = _plain_str(field.get("image_url"))
        if not challenge_ref or not image_url:
            return VerificationChallenge(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="captcha reply incomplete"
            )
        try:
            image = self._http().get(
                urljoin(self.account.resolved_base_url() + "/", image_url.lstrip("/")),
                headers=self._headers(),
                timeout=self._timeout,
            )
        except requests.RequestException as exc:
            return VerificationChallenge(ok=False, error_code=ERROR_UNREACHABLE, error_detail=str(exc))
        if image.status_code >= 400 or not image.content:
            return VerificationChallenge(
                ok=False,
                error_code=ERROR_PROVIDER_ERROR,
                error_detail=f"captcha image answered {image.status_code}",
            )
        return VerificationChallenge(
            ok=True,
            challenge_ref=challenge_ref,
            image=bytes(image.content),
            image_type=(image.headers.get("content-type") or "image/png").split(";")[0],
            help_text=_plain_str(field.get("help_text")),
        )

    def send_verification_code(self, challenge_ref: str, answer: str) -> VerificationResult:
        if not self.account.username:
            return VerificationResult(ok=False, error_code=ERROR_NOT_CONFIGURED)
        try:
            response = self._http().post(
                self._url(SEND_CODE_PATH),
                json={
                    "phone": self.account.username,
                    "action": "login",
                    "captcha": (answer or "").strip(),
                    "captcha_ref": (challenge_ref or "").strip(),
                },
                headers=self._headers(),
                timeout=self._timeout,
            )
        except requests.RequestException as exc:
            return VerificationResult(ok=False, error_code=ERROR_UNREACHABLE, error_detail=str(exc))
        payload = _json(response)
        if _demands_attestation(response, payload):
            return VerificationResult(
                ok=False, error_code=ERROR_ATTESTATION_REQUIRED, error_detail=_message(payload)
            )
        results = (payload or {}).get("results") if isinstance(payload, dict) else None
        if response.status_code >= 400 or not isinstance(results, dict):
            return VerificationResult(
                ok=False,
                error_code=(
                    ERROR_VERIFICATION_REJECTED
                    if 400 <= response.status_code < 500
                    else ERROR_PROVIDER_ERROR
                ),
                error_detail=_message(payload) or f"code request answered {response.status_code}",
            )
        session = _plain_str(results.get("uuid"))
        if not session:
            return VerificationResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="no code session in reply"
            )
        self._store_secrets(**{SECRET_VERIFICATION: session})
        return VerificationResult(ok=True, expires_in=_int(results.get("expires_in")))

    def confirm_verification(self, code: str) -> VerificationResult:
        session = self.account.get_secret(SECRET_VERIFICATION)
        if not session:
            return VerificationResult(
                ok=False,
                error_code=ERROR_VERIFICATION_REJECTED,
                error_detail="ask for a new code first",
            )
        try:
            response = self._http().post(
                self._url(VERIFY_CODE_PATH),
                json={
                    "phone": self.account.username,
                    "otp": (code or "").strip(),
                    "uuid": session,
                },
                headers=self._headers(),
                timeout=self._timeout,
            )
        except requests.RequestException as exc:
            return VerificationResult(ok=False, error_code=ERROR_UNREACHABLE, error_detail=str(exc))
        payload = _json(response)
        if _demands_attestation(response, payload):
            return VerificationResult(
                ok=False, error_code=ERROR_ATTESTATION_REQUIRED, error_detail=_message(payload)
            )
        if response.status_code >= 400:
            return VerificationResult(
                ok=False,
                error_code=(
                    ERROR_VERIFICATION_REJECTED
                    if response.status_code < 500
                    else ERROR_PROVIDER_ERROR
                ),
                error_detail=_message(payload) or f"code check answered {response.status_code}",
            )
        # The success body was never captured; the capture's best guess is
        # that it is the login's. Take a token when there is one, and when
        # there is not, the device is trusted now — so the password logs in.
        access = _plain_str((payload or {}).get("access")) if isinstance(payload, dict) else ""
        if access:
            self._store_secrets(
                **{
                    SECRET_ACCESS: access,
                    SECRET_REFRESH: _plain_str(payload.get("refresh")),
                    SECRET_VERIFICATION: "",
                }
            )
            return VerificationResult(ok=True)
        self._store_secrets(**{SECRET_VERIFICATION: ""})
        token, error, detail = self._login()
        if not token:
            return VerificationResult(ok=False, error_code=error, error_detail=detail)
        return VerificationResult(ok=True)


# --- the shared basket --------------------------------------------------------
@contextmanager
def _cart_lock(account, *, wait_seconds: float = CART_LOCK_WAIT_SECONDS):
    """Take turns on the provider's one basket. Yields whether we hold it.

    Redis ``SET NX`` with an expiry, so a process that dies holding it frees it
    within a minute. Fail-open when Redis is unreachable: the basket read-back
    and Qareeb's own hash still stop a checkout buying what it did not mean to,
    and a shop must not stop selling because a cache is down.
    """
    key = f"pointy:integrations:qareeb:basket:{account.pk}"
    token = uuid.uuid4().hex
    deadline = time.monotonic() + wait_seconds
    held = False
    owned = True
    while True:
        try:
            held = bool(cache.add(key, token, CART_LOCK_SECONDS))
        except Exception:  # noqa: BLE001 - no usable Redis: proceed unguarded
            logger.warning("qareeb basket lock unavailable", exc_info=True)
            held, owned = True, False
            break
        if held or time.monotonic() >= deadline:
            break
        time.sleep(0.15)
    try:
        yield held
    finally:
        if held and owned:
            try:
                if cache.get(key) == token:
                    cache.delete(key)
            except Exception:  # noqa: BLE001
                pass


# --- parsing ------------------------------------------------------------------
_ONE_SECOND = timedelta(seconds=1)


class _CartItem:
    __slots__ = ("product_id", "quantity", "cost")

    def __init__(self, product_id: str, quantity: int, cost: Decimal | None):
        self.product_id = product_id
        self.quantity = quantity
        self.cost = cost


class _Cart:
    __slots__ = ("hash", "items", "pin_required", "quick_switch")

    def __init__(
        self,
        hash_: str,
        items: list[_CartItem],
        pin_required: bool,
        quick_switch: bool = False,
    ):
        self.hash = hash_
        self.items = items
        self.pin_required = pin_required
        self.quick_switch = quick_switch


def _parse_cart(payload) -> _Cart | None:
    if not isinstance(payload, dict):
        return None
    hash_ = _plain_str(payload.get("hash"))
    rows = payload.get("items")
    if not hash_ or not isinstance(rows, list):
        return None
    items = []
    for row in rows:
        if not isinstance(row, dict):
            return None
        product = row.get("product")
        if not isinstance(product, dict):
            return None
        product_id = _plain_str(product.get("id"))
        if not product_id:
            return None
        items.append(
            _CartItem(
                product_id=product_id,
                quantity=_int(row.get("quantity")) or 0,
                cost=_decimal(product.get("cost")),
            )
        )
    return _Cart(
        hash_,
        items,
        _truthy(payload.get("is_pin_required")),
        _truthy(payload.get("is_quick_switch_enabled")),
    )


def _parse_brand(raw, *, category: str) -> VoucherBrand | None:
    if not isinstance(raw, dict):
        return None
    code = _plain_str(raw.get("code"))
    name = _plain_str(raw.get("ar_desc")) or _plain_str(raw.get("en_desc"))
    if not code or not name:
        return None
    items = []
    for product in raw.get("products") or ():
        if not isinstance(product, dict):
            continue
        item_code = _plain_str(product.get("id"))
        label = _plain_str(product.get("desc"))
        cost = _decimal(product.get("cost"))
        if not item_code or not label or cost is None:
            continue
        items.append(
            VoucherItem(
                code=item_code,
                label=label,
                cost=_quantize(cost),
                suggested_price=_quantize(_decimal(product.get("price"))),
                face_amount=_decimal(product.get("amount")),
            )
        )
    return VoucherBrand(
        code=code,
        name=name,
        name_en=_plain_str(raw.get("en_desc")),
        category=category,
        currency=_plain_str(raw.get("product_currency")) or "LYD",
        logo_path=_plain_str(raw.get("logo")),
        items=tuple(items),
    )


def _with_items_known(brand: VoucherBrand, known: bool) -> VoucherBrand:
    return VoucherBrand(
        code=brand.code,
        name=brand.name,
        name_en=brand.name_en,
        category=brand.category,
        currency=brand.currency,
        logo_path=brand.logo_path,
        items=brand.items,
        items_known=known,
    )


def _printed_fields(row: dict) -> dict:
    """What a receipt prints for one card, from a checkout or a log row.

    The same keys whichever of the two it came from, so a card whose checkout
    reply was lost and was later found in the log prints exactly like one that
    was answered at the counter.
    """
    brand = _plain_str(row.get("mno_type_ar")) or _plain_str(row.get("mno_type__name")) or _plain_str(
        row.get("mno_type") if isinstance(row.get("mno_type"), str) else ""
    )
    printed = {
        "brand": brand,
        "product": _plain_str(row.get("product")),
        "code": _plain_str(row.get("code")),
        "serial": _plain_str(row.get("SN")),
        "instructions": _plain_str(row.get("instructions_print")),
        "help": _plain_str(row.get("help_print")),
        "expiry": _plain_str(row.get("expiry_date")),
        "ccv": _plain_str(row.get("ccv")),
    }
    return {key: value for key, value in printed.items() if value}


def _receipt_for(card: dict, *, order_reference: str) -> dict:
    return {
        "order_reference": order_reference,
        "voucher_id": _plain_str(card.get("id")),
        "tran_ref": _plain_str(card.get("tran_ref")),
        "purchase_date": _plain_str(card.get("purchase_date")),
        "purchase_price": _plain_str(card.get("purchase_price")),
        "printed": _printed_fields(card),
    }


def _json(response):
    try:
        return response.json()
    except (ValueError, AttributeError):
        pass
    text = getattr(response, "text", "") or ""
    try:
        return json.loads(text) if text else None
    except ValueError:
        return None


def _message(payload) -> str:
    """The provider's own words for a refusal, from whichever key it used."""
    if isinstance(payload, str):
        return payload.strip()[:300]
    if not isinstance(payload, dict):
        return ""
    for key in ("error", "detail", "message", "msg"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()[:300]
        if isinstance(value, list) and value and isinstance(value[0], str):
            return value[0].strip()[:300]
    errors = payload.get("non_field_errors") or payload.get("errors")
    if isinstance(errors, list) and errors and isinstance(errors[0], str):
        return errors[0].strip()[:300]
    for value in payload.values():
        if isinstance(value, list) and value and isinstance(value[0], str):
            return value[0].strip()[:300]
    return ""


def _never_sent(exc) -> bool:
    """Whether a failed request provably never reached the provider.

    Only a failure to *open* the connection proves that — refused, unresolved,
    timed out while connecting. Anything after the socket opened (a reset, a
    read timeout, a dropped keep-alive) may have been read and acted on, and a
    checkout in that state is a card that may have been bought.
    """
    from urllib3.exceptions import ConnectTimeoutError

    if isinstance(exc, (requests.ConnectTimeout, requests.exceptions.InvalidURL)):
        return True
    if isinstance(exc, requests.ConnectionError):
        reason = exc.args[0] if exc.args else None
        reason = getattr(reason, "reason", reason)
        # NewConnectionError and NameResolutionError both derive from it.
        return isinstance(reason, ConnectTimeoutError)
    return False


def _is_new_device(message: str) -> bool:
    lowered = (message or "").lower()
    return "جهاز جديد" in message or "otp" in lowered or "مؤقتة" in message


#: Words a server uses when it wants proof the caller is its own app.
_ATTESTATION_MARKERS = (
    "app check",
    "appcheck",
    "app-check",
    "firebase",
    "attest",
    "integrity",
    "play integrity",
    "devicecheck",
)


def _demands_attestation(response, payload) -> bool:
    """Whether a refusal is the provider demanding its own app, not a password.

    Deliberately narrow: only a 401/403 that *says so*. Qareeb does not ask
    today — see the module docstring — and a false positive here would hide
    an ordinary wrong password behind a scarier message.
    """
    if response is None or response.status_code not in (401, 403):
        return False
    text = _message(payload).lower()
    if not text:
        text = (getattr(response, "text", "") or "")[:500].lower()
    return any(marker in text for marker in _ATTESTATION_MARKERS)


def _classify_refusal(message: str, status: int) -> str:
    """A stable code for a refusal, from the provider's Arabic wording."""
    text = message or ""
    lowered = text.lower()
    if "رصيد" in text or "balance" in lowered:
        return ERROR_INSUFFICIENT_FLOAT
    if any(
        marker in text
        for marker in ("غير متوفر", "غير متاح", "نفذ", "نفد", "لا يوجد مخزون", "المخزون")
    ) or "stock" in lowered:
        return ERROR_OUT_OF_STOCK
    if "الرقم السري" in text or "pin" in lowered:
        return ERROR_PIN_REQUIRED
    if status == 429:
        return ERROR_BUSY
    return ERROR_PROVIDER_ERROR


def _token_expired(token: str, *, leeway_seconds: int = 120) -> bool:
    """Whether a JWT's own ``exp`` has passed. Unreadable is not expired.

    The signature is not ours to check — Qareeb is the only judge of its own
    tokens — so this only saves a round trip that would certainly be refused.
    """
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        exp = int(claims.get("exp"))
    except (IndexError, ValueError, TypeError, AttributeError):
        return False
    return exp <= time.time() + leeway_seconds


def _same_phone(left, right) -> bool:
    a = "".join(ch for ch in str(left or "") if ch.isdigit())
    b = "".join(ch for ch in str(right or "") if ch.isdigit())
    if not a or not b:
        return False
    # 0912345678 and 218912345678 are the same line.
    return a[-9:] == b[-9:]


def _local_datetime(value) -> datetime | None:
    """Qareeb's timestamps are a bare wall clock in Libyan time."""
    text = _plain_str(value)
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=business_timezone())
    return parsed.astimezone(utc_timezone.utc)


def _truthy(value) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return bool(value)


def _plain_str(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _decimal(value) -> Decimal | None:
    if value is None or value == "":
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def _quantize(value) -> Decimal | None:
    if value is None:
        return None
    return Decimal(value).quantize(_CENT, rounding=ROUND_HALF_UP)
