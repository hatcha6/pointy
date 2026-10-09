"""«كروت دفتر» — the company's own cards, bought through the relay.

The other drivers drive somebody else's website with credentials the shop typed
in. This one talks to the company's own relay with the shop's installation
token (:mod:`apps.integrations.relay_link`): the relay holds the wholesaler
account (BN Plus), buys each card the moment the shop's invoice is paid, and
charges it to the shop's voucher balance in its Daftar wallet. So there is
nothing to configure but the relay link, and the shelf is ours: our
categories, our order, our promotions (``VOUCHER_SHOP_PLAN.md``).

What this driver may assume, and what it must not:

* **A purchase is idempotent on a key of ours.** ``recharge`` sends the
  attempt's key (``recharge.attempt_key``); the relay answers a replay with the
  first purchase. So an answer that never arrived is settled by reading the
  purchase back under the same key (:meth:`PointyProvider.attempt_outcome`),
  never by matching a purchase log on cost and time.
* **It is still at most once.** The key makes a replay harmless; whether to
  replay is the at-most-once guard's decision, never this driver's. A purchase
  that may have happened is ``indeterminate`` — the relay's ``202``, its
  ``in_flight``, a succeeded purchase whose codes could not be read back yet,
  an error status from something in front of the relay, a request that left
  and got no answer. Only a request that never reached the relay, or a refusal
  the relay itself states, is definite.
* **The relay keeps no codes.** They arrive in the purchase answer and are kept
  on the fulfillment, exactly like Qareeb's.
* **Prices carry two places** (cost, price and the shop's books all keep two),
  and money is dinars.

Besides cards, the same relay sells **direct top-up and bill payments**
(``DIRECT_TOPUP_PLAN.md``): credit sent straight to a phone number abroad, a bill
paid in another country. They ride the same guard, the same key and the same
balance — ``recharge`` sends an ``air:`` / ``bill:`` option code to the relay's
service orders instead of its card purchases, and ``attempt_outcome`` reads either
back by what the purchase says it is (``kind``) — and add three reads of their own:
the directory of countries, networks and billers (:meth:`PointyProvider.services_directory`),
the network a number belongs to (``service_detect``) and the exact price of one
thing (``service_quote``). What is specific to them on the wire — reading the
directory, composing the order, writing the slip in Arabic — lives in
:mod:`.pointy_services`.

The relay link is read on the calling thread and pinned for
:func:`~apps.integrations.providers.base.in_parallel`'s workers, so a worker
building this driver never queries the database.
"""

from __future__ import annotations

import logging
import re
from dataclasses import replace

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured

from apps.core.relay import RelayControlError

from .. import relay_link, services_options
from ..masking import mask_numbers
from ..telemetry import STEP_PARSE, STEP_SUBMIT
from . import pointy_services
from .base import (
    ATTEMPT_ABSENT,
    ATTEMPT_CHARGED,
    ATTEMPT_REFUSED,
    ATTEMPT_UNKNOWN,
    ERROR_BUSY,
    ERROR_INDETERMINATE,
    ERROR_INSUFFICIENT_FLOAT,
    ERROR_NOT_CONFIGURED,
    ERROR_NOT_FOUND,
    ERROR_OUT_OF_STOCK,
    ERROR_PRICE_CHANGED,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAUTHORIZED,
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    AttemptOutcome,
    IntegrationProvider,
    ProbeResult,
    RechargeResult,
    ServiceDetectResult,
    ServiceQuoteResult,
    ServicesDirectoryResult,
    VoucherBrand,
    VoucherCatalogResult,
    VoucherCountry,
    VoucherItem,
    VoucherLogo,
    register,
)
from .relay_wire import decimal as _decimal
from .relay_wire import instant as _instant
from .relay_wire import integer as _int
from .relay_wire import json_object as _json_object
from .relay_wire import money as _money
from .relay_wire import money_text as _money_text
from .relay_wire import plain_number as _plain_number
from .relay_wire import text as _text

logger = logging.getLogger(__name__)

#: A wallet read, a purchase read back: small answers.
READ_TIMEOUT_SECONDS = 15
#: The whole shelf, a few hundred cards at most.
CATALOG_TIMEOUT_SECONDS = 30
IMAGE_TIMEOUT_SECONDS = 20
#: The services directory: every country with its operators and billers, the
#: biggest document the relay sends (a few hundred KB).
DIRECTORY_TIMEOUT_SECONDS = 30
#: Detecting a number's network may ask the supplier, who is slower than the relay.
DETECT_TIMEOUT_SECONDS = 20
#: A quote is answered from the relay's own directory.
QUOTE_TIMEOUT_SECONDS = 15
#: The money call waits longer than the relay's own call to the wholesaler
#: (45 s): an answer abandoned is an outcome nobody knows until the purchase is
#: read back, so it is worth waiting for one. Kept well under
#: ``reconciliation.ATTEMPT_SETTLE_AFTER``, which must never meet a purchase
#: whose own request is still waiting.
DEFAULT_PURCHASE_TIMEOUT_SECONDS = 60
#: A direct top-up or bill payment waits for the supplier too, and the relay's
#: own budget for one is 45 s (the supplier) + 20 s (its refund and its answer)
#: + 5 s of slack = 70 s: the shop waits longer than that, so an answer is not
#: abandoned while the relay is still about to give it. Still under
#: ``reconciliation.ATTEMPT_SETTLE_AFTER`` (120 s), which must never meet an
#: order whose request is still waiting.
DEFAULT_SERVICE_PURCHASE_TIMEOUT_SECONDS = 90
SERVICE_PURCHASE_TIMEOUT_RANGE = (80, 110)

#: A catalog picture's path: ``sha256:<hex>``. Nothing else is ever fetched —
#: the path comes off the wire, and must never become an address of its own.
_IMAGE_PATH = re.compile(r"sha256:([0-9a-f]{64})")
#: The relay's word for each kind of supplier refusal (``502``), mapped to the
#: driver vocabulary. Each carries a failed, refunded purchase: the relay says
#: so itself, and that — not the status — is what makes it definite.
#:
#: The company's supplier accounts are not the shop's to fix, so a supplier
#: that has no credit left or turned our credentials down is simply
#: ``unavailable`` (never ``unauthorized``, which tells a shop to check a login
#: it does not have), and one that could not be reached before anything was
#: sent is ``unreachable``.
_SUPPLIER_REFUSALS = {
    # The words the relay says to shops (it never names its suppliers); the
    # ``supplier_*`` ones are what an older relay said.
    "out_of_stock": ERROR_OUT_OF_STOCK,
    "refused": ERROR_PROVIDER_ERROR,
    "unavailable": ERROR_UNAVAILABLE,
    "supplier_out_of_stock": ERROR_OUT_OF_STOCK,
    "supplier_refused": ERROR_PROVIDER_ERROR,
    "supplier_unavailable": ERROR_PROVIDER_ERROR,
    "supplier_credit": ERROR_UNAVAILABLE,
    "supplier_unauthorized": ERROR_UNAVAILABLE,
    "supplier_unreachable": ERROR_UNREACHABLE,
}
#: A purchase's own ``error_code`` when it failed, as far as this shop cares:
#: the same words a ``502`` carries, for the replay of one and for reading one back.
_FAILED_PURCHASE_CODES = {
    **_SUPPLIER_REFUSALS,
    "item_unavailable": ERROR_OUT_OF_STOCK,
    "unknown_operator": ERROR_OUT_OF_STOCK,
    "unknown_biller": ERROR_OUT_OF_STOCK,
    "price_changed": ERROR_PRICE_CHANGED,
}


def _purchase_timeout() -> int:
    return int(
        getattr(
            settings,
            "POINTY_RELAY_VOUCHER_PURCHASE_TIMEOUT_SECONDS",
            DEFAULT_PURCHASE_TIMEOUT_SECONDS,
        )
    )


def _service_purchase_timeout() -> int:
    """How long an order for a service waits for the relay: configurable, but kept
    between the relay's own budget and the moment a settle may read it back."""
    low, high = SERVICE_PURCHASE_TIMEOUT_RANGE
    wanted = int(
        getattr(
            settings,
            "POINTY_RELAY_SERVICE_PURCHASE_TIMEOUT_SECONDS",
            DEFAULT_SERVICE_PURCHASE_TIMEOUT_SECONDS,
        )
    )
    return max(low, min(wanted, high))


@register("pointy")
class PointyProvider(IntegrationProvider):
    """The relay's voucher shop for one shop, as a driver."""

    #: No per-card history: a card belongs to nobody until it is sold.
    history_kinds = ()
    reads_attempts = True

    def __init__(self, account):
        super().__init__(account)
        #: The ``ETag`` of the shelf the shop's mirror holds, set by the sync
        #: (:mod:`apps.integrations.vouchers`) before it asks, so an unchanged
        #: shelf answers ``not_modified`` and nothing is read or written.
        self.catalog_etag = ""

    # --- the relay link ----------------------------------------------------
    def _link(self):
        """``(link, None)``, or ``(None, (error_code, detail))``."""
        link = relay_link.current()
        if link is None:
            return None, (ERROR_NOT_CONFIGURED, "this shop is not linked to the relay")
        try:
            link.client  # noqa: B018 - built (once) here so a bad setup is a refusal
        except ImproperlyConfigured as exc:
            return None, (ERROR_NOT_CONFIGURED, str(exc))
        return link, None

    # --- the voucher balance -------------------------------------------------
    def probe(self) -> ProbeResult:
        """The voucher balance, from the shop's wallet on the relay."""
        link, refusal = self._link()
        if refusal is not None:
            return ProbeResult(ok=False, error_code=refusal[0], error_detail=refusal[1])
        try:
            payload = link.client.get_wallet(
                access_token=link.access_token, timeout=READ_TIMEOUT_SECONDS
            )
        except RelayControlError as exc:
            code, detail = _read_refusal(exc)
            return ProbeResult(ok=False, error_code=code, error_detail=detail)
        self._note(STEP_PARSE)
        vouchers = payload.get("vouchers") if isinstance(payload, dict) else None
        if not isinstance(vouchers, dict):
            # A relay from before the voucher shop.
            return ProbeResult(
                ok=False, error_code=ERROR_UNAVAILABLE, error_detail="the relay sells no vouchers"
            )
        balance = _money(vouchers.get("balance"))
        if balance is None:
            self._observe(shape_ok=False)
            return ProbeResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="no voucher balance"
            )
        if vouchers.get("configured") is False:
            return ProbeResult(
                ok=False, error_code=ERROR_UNAVAILABLE, error_detail="vouchers_unconfigured"
            )
        return ProbeResult(ok=True, balance=balance)

    # --- the shelf ---------------------------------------------------------------
    def voucher_catalog(self) -> VoucherCatalogResult:
        """The whole shelf in one read, or ``not_modified`` against ``catalog_etag``."""
        return self._catalog(etag=(self.catalog_etag or "").strip())

    def voucher_brand(self, brand_code: str) -> VoucherCatalogResult:
        """One brand, read from the whole shelf (the relay has no brand read)."""
        listing = self._catalog(etag="")
        if not listing.ok:
            return listing
        for brand in listing.brands:
            if brand.code == brand_code:
                return VoucherCatalogResult(ok=True, brands=(brand,), countries=listing.countries)
        return VoucherCatalogResult(
            ok=False, error_code=ERROR_NOT_FOUND, error_detail="no such brand on the shelf"
        )

    def _catalog(self, *, etag: str) -> VoucherCatalogResult:
        link, refusal = self._link()
        if refusal is not None:
            return VoucherCatalogResult(ok=False, error_code=refusal[0], error_detail=refusal[1])
        try:
            payload, version = link.client.get_voucher_catalog(
                access_token=link.access_token, etag=etag, timeout=CATALOG_TIMEOUT_SECONDS
            )
        except RelayControlError as exc:
            code, detail = _read_refusal(exc)
            return VoucherCatalogResult(ok=False, error_code=code, error_detail=detail)
        if payload is None:
            return VoucherCatalogResult(ok=True, not_modified=True, version=version or etag)
        self._note(STEP_PARSE)
        if not isinstance(payload, dict) or not isinstance(payload.get("brands"), list):
            self._observe(shape_ok=False)
            return VoucherCatalogResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="the catalog lists no brands"
            )
        brands, countries = _parse_catalog(payload)
        if not version and payload.get("version"):
            # The header is the ETag; the body's version is the same edition,
            # quoted the way an ETag is.
            version = f'"{payload["version"]}"'
        return VoucherCatalogResult(
            ok=True,
            brands=brands,
            countries=countries,
            version=str(version or "")[:128],
            test_mode=payload.get("test_mode") is True,
        )

    def voucher_logo(self, logo_path: str) -> VoucherLogo:
        """A catalog picture — a brand's logo or a country's flag — by its hash."""
        match = _IMAGE_PATH.fullmatch((logo_path or "").strip())
        if match is None:
            return VoucherLogo(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="not a catalog picture"
            )
        link, refusal = self._link()
        if refusal is not None:
            return VoucherLogo(ok=False, error_code=refusal[0], error_detail=refusal[1])
        digest = match.group(1)
        try:
            data, _content_type = link.client.get_voucher_image(
                access_token=link.access_token, digest=digest, timeout=IMAGE_TIMEOUT_SECONDS
            )
        except RelayControlError as exc:
            code, detail = _read_refusal(exc)
            return VoucherLogo(ok=False, error_code=code, error_detail=detail)
        if not data:
            return VoucherLogo(ok=False, error_code=ERROR_UNEXPECTED, error_detail="empty picture")
        return VoucherLogo(ok=True, data=data, url=f"relay:/v1/vouchers/images/{digest}")

    # --- the services: direct top-up and bill payments -----------------------------
    def services_directory(self, etag: str = "") -> ServicesDirectoryResult:
        """Every country with its operators and billers, or ``not_modified`` against ``etag``."""
        link, refusal = self._link()
        if refusal is not None:
            return ServicesDirectoryResult(ok=False, error_code=refusal[0], error_detail=refusal[1])
        etag = (etag or "").strip()
        try:
            payload, version = link.client.get_services_directory(
                access_token=link.access_token, etag=etag, timeout=DIRECTORY_TIMEOUT_SECONDS
            )
        except RelayControlError as exc:
            code, detail = pointy_services.read_refusal(exc, _error_body(exc))
            return ServicesDirectoryResult(ok=False, error_code=code, error_detail=detail)
        if payload is None:
            return ServicesDirectoryResult(ok=True, not_modified=True, version=version or etag)
        self._note(STEP_PARSE)
        result = pointy_services.directory(payload, etag=str(version or "")[:128])
        if not result.ok:
            self._observe(shape_ok=False)
        return result

    def service_detect(self, country: str, phone: str) -> ServiceDetectResult:
        """The operator the relay detects for ``phone`` in ``country``.

        The relay's own "no network found" and "not a number" are answers
        (``ok`` with a ``reason``); only a relay that cannot be asked, or that
        answers something unreadable, is a fault.
        """
        link, refusal = self._link()
        if refusal is not None:
            return ServiceDetectResult(ok=False, error_code=refusal[0], error_detail=refusal[1])
        try:
            payload = link.client.post_service_detect(
                access_token=link.access_token,
                country=country,
                phone=phone,
                timeout=DETECT_TIMEOUT_SECONDS,
            )
        except RelayControlError as exc:
            body = _error_body(exc)
            answered = pointy_services.detect_refusal(exc, body)
            if answered is not None:
                return answered
            code, detail = pointy_services.read_refusal(exc, body)
            return ServiceDetectResult(ok=False, error_code=code, error_detail=detail)
        self._note(STEP_PARSE)
        result = pointy_services.detection(payload)
        if not result.ok:
            self._observe(shape_ok=False)
        return result

    def service_quote(self, request: dict) -> ServiceQuoteResult:
        """The exact price of one top-up or bill payment, from the relay's own directory.

        Spends nothing. A refusal in the relay's words (``amount_out_of_range`` …)
        is an answer (``refusal``), not a fault.
        """
        link, refusal = self._link()
        if refusal is not None:
            return ServiceQuoteResult(ok=False, error_code=refusal[0], error_detail=refusal[1])
        try:
            payload = link.client.quote_service(
                access_token=link.access_token, payload=request, timeout=QUOTE_TIMEOUT_SECONDS
            )
        except RelayControlError as exc:
            body = _error_body(exc)
            answered = pointy_services.quote_refusal(exc, body)
            if answered is not None:
                return answered
            code, detail = pointy_services.read_refusal(exc, body)
            return ServiceQuoteResult(ok=False, error_code=code, error_detail=detail)
        self._note(STEP_PARSE)
        result = pointy_services.quotation(payload, request=request)
        if not result.ok:
            self._observe(shape_ok=False)
        return result

    def _service_ref(self, option):
        """``option``'s operator or biller in the shop's mirror, or ``None``.

        An option code names the operator but not its country, and every country's
        payload is a document: looking the operator up across all of them for each
        order sent or read back is a read of the whole directory per row. The sale
        knows the country (the fulfillment's ``package_id``, written from the
        sealed quote), so a driver ``bind()``-ed to that fulfillment looks in that
        country only — and an operator that country no longer lists is unknown,
        not found in some other country's list. Unbound (no fulfillment to ask),
        every country is searched.

        Read on the calling thread (a purchase is never made from a worker).
        Never raises: the slip of a purchase that happened must still be
        printable when the mirror cannot be read, in the relay's own words.
        """
        from .. import services_mirror

        if option is None:
            return None
        bound = self.fulfillment
        country = ""
        if bound is not None and getattr(bound, "option_code", "") == option.code:
            country = str(getattr(bound, "package_id", "") or "")
        try:
            return services_mirror.find_service(
                self.account, option.kind, option.service_id, country=country
            )
        except Exception:  # noqa: BLE001 - see the docstring
            # Which service, not which option: an option code may carry an invoice.
            logger.warning(
                "could not read the services mirror for %s %s",
                option.kind,
                option.service_id,
                exc_info=True,
            )
            return None

    def _service_context(self, option, found):
        """What a service slip is written with: the option, its service, the currency names.

        The names are the mirror's ``{ISO code: Arabic name}``, so an amount reads
        «5,000 فرنك أفريقي». Read on the calling thread, like :meth:`_service_ref`
        — and, like it, never raises: a slip printed without them names an amount
        by its currency code, which is better than no slip for a purchase that
        happened.
        """
        from .. import services_mirror

        try:
            names = services_mirror.currency_names(self.account)
        except Exception:  # noqa: BLE001 - see the docstring
            logger.warning(
                "could not read the currency names of the services mirror", exc_info=True
            )
            names = {}
        return pointy_services.ServiceContext(option, found, names)

    def _send_service(self, subscriber_ref: str, item: str, *, expected_cost, key: str):
        """Send one direct top-up or bill payment: ``item`` is its option code.

        ``subscriber_ref`` is who it is for — an E.164 phone number, or the
        account a bill is paid on. The option code does not say which country
        the operator is in, and the relay wants one, so the operator is looked up
        in the shop's mirror; one that is no longer there is a definite refusal
        (nothing was sent).
        """
        option = services_options.parse_option_code(item)
        if option is None:
            # Never sent as a card: a service option nobody can read is nobody's card.
            return RechargeResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="malformed service option"
            )
        subscriber_ref = (subscriber_ref or "").strip()
        if not services_options.valid_subscriber_ref(option.kind, subscriber_ref):
            return RechargeResult(
                ok=False, error_code=ERROR_NOT_FOUND, error_detail="malformed subscriber"
            )
        link, refusal = self._link()
        if refusal is not None:
            return RechargeResult(ok=False, error_code=refusal[0], error_detail=refusal[1])
        found = self._service_ref(option)
        if found is None:
            word = "operator" if option.kind == services_options.KIND_AIRTIME else "biller"
            return RechargeResult(
                ok=False, error_code=ERROR_OUT_OF_STOCK, error_detail=f"unknown_{word}"
            )
        body = pointy_services.order_body(
            option, found, subscriber_ref=subscriber_ref, key=key, expected_cost=expected_cost
        )
        # Everything the shop reads from its own database comes before the money.
        context = self._service_context(option, found)

        # The money. Recorded as the step BEFORE the request, exactly as for a card.
        self._note(STEP_SUBMIT)
        try:
            status, payload = link.client.create_service_order(
                access_token=link.access_token,
                payload=body,
                timeout=_service_purchase_timeout(),
            )
        except RelayControlError as exc:
            self._observe(http_status=exc.status_code)
            return _masked(_refused_purchase(exc, {}))
        self._observe(http_status=status)
        self._note(STEP_PARSE)
        return _masked(_answered_purchase(status, payload, {}, service=context))

    # --- buying one card ---------------------------------------------------------
    def recharge(
        self, card_no: str, option_code: str, *, expected_cost=None, attempt_key: str = ""
    ):
        """Buy one card: ``option_code`` is the catalog item's key.

        ``expected_cost`` is the most the shop will pay (``recharge.cost_ceiling``:
        what the sale was rung up at for a card, what the customer pays for a
        service); the relay charges its current price when that is not higher and
        refuses otherwise (``price_changed``), so the shop never pays more than it
        sold against. ``card_no`` is ignored: a card belongs to nobody until it is sold.

        An ``air:`` / ``bill:`` option code is not a card but one of the company's
        direct services — a top-up sent to a phone number, a bill paid — and goes
        to the relay's service orders instead, with ``card_no`` as its subscriber.
        The guard around it is the same: one attempt, one key, and an outcome that
        is only definite when the request never left or the relay said no itself.
        """
        item = (option_code or "").strip()
        key = (attempt_key or "").strip()
        if not item:
            return RechargeResult(ok=False, error_code=ERROR_UNEXPECTED, error_detail="no card")
        if not key or len(key) > 100:
            # Without a key of ours a replay would be a second card: refuse
            # rather than send something that cannot be read back.
            return RechargeResult(
                ok=False, error_code=ERROR_UNEXPECTED, error_detail="no attempt key"
            )
        if services_options.is_service_option(item):
            return self._send_service(card_no, item, expected_cost=expected_cost, key=key)
        link, refusal = self._link()
        if refusal is not None:
            return RechargeResult(ok=False, error_code=refusal[0], error_detail=refusal[1])
        words = self._card_words(item)

        # The money. Recorded as the step BEFORE the request, so a process that
        # dies mid-call leaves telemetry saying the write may be out.
        self._note(STEP_SUBMIT)
        try:
            status, payload = link.client.create_voucher_purchase(
                access_token=link.access_token,
                item=item,
                idempotency_key=key,
                max_unit_price=_money_text(expected_cost),
                quantity=1,
                timeout=_purchase_timeout(),
            )
        except RelayControlError as exc:
            self._observe(http_status=exc.status_code)
            return _refused_purchase(exc, words)
        self._observe(http_status=status)
        self._note(STEP_PARSE)
        return _answered_purchase(status, payload, words)

    def attempt_outcome(self, attempt_key: str, *, option_code: str = "") -> AttemptOutcome:
        """The purchase sent under ``attempt_key``, read back from the relay.

        A card or a service, whichever the purchase says it is (``kind``).
        ``option_code`` is what the attempt was a write of: a service's slip names
        its network by the shop's Arabic name for it, which only the shop's mirror
        knows, and its invoice, which only the option code does.
        """
        key = (attempt_key or "").strip()
        link, refusal = self._link()
        if refusal is not None or not key:
            code, detail = refusal or (ERROR_UNEXPECTED, "no attempt key")
            return AttemptOutcome(state=ATTEMPT_UNKNOWN, error_code=code, error_detail=detail)
        try:
            payload = link.client.get_voucher_purchase(
                access_token=link.access_token, idempotency_key=key, timeout=READ_TIMEOUT_SECONDS
            )
        except RelayControlError as exc:
            body = _json_object(exc.body)
            if exc.status_code == 404 and body is not None and body.get("code") == "not_found":
                # The relay's own "no such purchase". Any other 404 — a relay
                # without the route answers {"error": "not found"}, a proxy
                # its own page — proves nothing.
                return AttemptOutcome(state=ATTEMPT_ABSENT)
            code, detail = _read_refusal(exc)
            return AttemptOutcome(state=ATTEMPT_UNKNOWN, error_code=code, error_detail=detail)
        self._note(STEP_PARSE)
        purchase = payload.get("purchase") if isinstance(payload, dict) else None
        if not isinstance(purchase, dict):
            self._observe(shape_ok=False)
            return AttemptOutcome(
                state=ATTEMPT_UNKNOWN, error_code=ERROR_UNEXPECTED, error_detail="no purchase"
            )
        balance = _money(payload.get("balance"))
        state = str(purchase.get("status") or "")
        reference = _text(purchase.get("id"), 64)
        if state == "succeeded":
            slip, pending = self._readable_receipt(purchase, option_code)
            if slip is None:
                # Bought, but its code (or token) is not in hand yet: ask again later.
                return AttemptOutcome(
                    state=ATTEMPT_UNKNOWN, reference=reference, error_detail=pending
                )
            return AttemptOutcome(
                state=ATTEMPT_CHARGED,
                reference=reference,
                receipt=slip,
                actual_cost=_money(purchase.get("unit_price")),
                balance_after=balance,
                at=_instant(purchase.get("completed_at")),
            )
        if state == "failed":
            detail = _failure_detail(purchase)
            if _text(purchase.get("kind"), 16) in services_options.KINDS:
                # The relay's own words may repeat the number it refused.
                detail = mask_numbers(detail)
            return AttemptOutcome(
                state=ATTEMPT_REFUSED,
                reference=reference,
                balance_after=balance,
                error_code=_FAILED_PURCHASE_CODES.get(
                    str(purchase.get("error_code") or ""), ERROR_PROVIDER_ERROR
                ),
                error_detail=detail,
            )
        return AttemptOutcome(state=ATTEMPT_UNKNOWN, reference=reference, error_detail=state)

    def _readable_receipt(self, purchase: dict, option_code: str) -> tuple[dict | None, str]:
        """The receipt of a succeeded purchase read back, or ``(None, why)``.

        ``why`` is the word for "not yet": a card's code, or a service's receipt
        (the token of a prepaid meter is read back from the supplier).
        """
        if _text(purchase.get("kind"), 16) in services_options.KINDS:
            option = services_options.parse_option_code(option_code)
            context = self._service_context(option, self._service_ref(option))
            return pointy_services.receipt(purchase, context), "receipt_pending"
        code_row = _first_code(purchase)
        if code_row is None:
            return None, "codes_pending"
        words = self._card_words(_text(purchase.get("item")))
        return _receipt(purchase, code_row, words), ""

    def _card_words(self, item: str) -> dict:
        """What the slip calls this card, from the shop's own mirror of the shelf.

        Read on the calling thread (a purchase is never made from a worker).
        Never raises: a slip without the brand's Arabic name still carries the
        code, which is what the customer paid for.
        """
        from ..models import IntegrationVoucher

        try:
            voucher = (
                IntegrationVoucher.objects.select_related("brand", "variant")
                .filter(account_id=self.account.pk, code=item)
                .first()
            )
        except Exception:  # noqa: BLE001 - see the docstring
            logger.warning("could not read the mirror for card %s", item, exc_info=True)
            return {}
        if voucher is None:
            return {}
        return {
            "brand": voucher.brand.name,
            "product": voucher.variant.name if voucher.variant_id else voucher.label,
            "instructions": voucher.brand.redeem_hint,
        }


# --- reading the shelf -------------------------------------------------------------
def _parse_catalog(document: dict) -> tuple[tuple[VoucherBrand, ...], tuple[VoucherCountry, ...]]:
    """The relay's catalog document in the driver vocabulary.

    Tolerant by item: one malformed card or brand is left out, the rest stand.
    Every brand's items are spelled out, so each is ``items_known`` — a card
    missing from the document is withdrawn, never merely unasked.
    """
    categories = {}
    for row in document.get("categories") or ():
        if isinstance(row, dict) and _text(row.get("key")):
            categories[_text(row.get("key"), 64)] = row
    countries = []
    seen = set()
    for row in document.get("countries") or ():
        if not isinstance(row, dict):
            continue
        code = _text(row.get("code"), 8).upper()
        if not code or code in seen:
            continue
        seen.add(code)
        countries.append(
            VoucherCountry(
                code=code,
                name=_text(row.get("name"), 120) or code,
                flag_path=_text(row.get("flag"), 80),
            )
        )
    brands = []
    for row in document.get("brands") or ():
        brand = _brand(row, categories)
        if brand is not None:
            brands.append(brand)
    return tuple(brands), tuple(countries)


def _brand(row, categories: dict) -> VoucherBrand | None:
    if not isinstance(row, dict):
        return None
    key = _text(row.get("key"), 32)
    name = _text(row.get("name"), 160)
    if not key or not name:
        return None
    items = tuple(item for item in map(_item, row.get("items") or ()) if item is not None)
    category_key = _text(row.get("category"), 64)
    category = categories.get(category_key) or {}
    currencies = [item.face_currency for item in items if item.face_currency]
    aliases = tuple(
        alias for alias in (_text(value, 120) for value in row.get("aliases") or ()) if alias
    )
    return VoucherBrand(
        code=key,
        name=name,
        category=_text(category.get("name"), 160),
        currency=currencies[0] if currencies else "LYD",
        logo_path=_text(row.get("logo"), 255),
        print_logo_path=_text(row.get("print_logo"), 255),
        items=items,
        items_known=True,
        rank=_int(row.get("rank")),
        featured=row.get("featured") is True,
        badge=_text(row.get("badge"), 64),
        category_key=category_key,
        category_rank=_int(category.get("rank")),
        redeem_hint=_text(row.get("redeem_hint"), 1000),
        aliases=aliases,
    )


def _item(row) -> VoucherItem | None:
    if not isinstance(row, dict):
        return None
    key = _text(row.get("key"), 64)
    cost = _money(row.get("unit_price"))
    if not key or cost is None:
        return None
    face_value = _decimal(row.get("face_value"))
    face_currency = _text(row.get("face_currency"), 8).upper()
    label = _text(row.get("label"), 160)
    if not label and face_value is not None:
        label = f"{_plain_number(face_value)} {face_currency}".strip()
    promo = row.get("promo") if isinstance(row.get("promo"), dict) else None
    return VoucherItem(
        code=key,
        label=label or key,
        cost=cost,
        suggested_price=_money(row.get("retail_price")),
        face_amount=face_value,
        # Only an explicit yes is sellable: a card is bought once the invoice
        # is paid, and must never be offered on a guess.
        available=row.get("available") is True,
        country=_text(row.get("country"), 8).upper(),
        face_currency=face_currency,
        rank=_int(row.get("rank")),
        badge=_text(promo.get("badge"), 64) if promo else "",
        promo_ends_at=_instant(promo.get("ends_at")) if promo else None,
        regular_price=_money(row.get("regular_retail_price")),
    )


# --- reading a purchase ------------------------------------------------------------
def _answered_purchase(
    status: int, payload, words: dict, service: pointy_services.ServiceContext | None = None
) -> RechargeResult:
    """A ``2xx`` purchase answer. Anything that does not prove the outcome is
    ``indeterminate``: the relay may well have bought the card.

    ``service`` is set when what was sent was a direct top-up or a bill payment
    rather than a card: a success then needs a *receipt* (the relay's
    ``receipt`` object, readable now) instead of a code.
    """
    purchase = payload.get("purchase") if isinstance(payload, dict) else None
    if not isinstance(purchase, dict):
        return _unknown("the relay answered without the purchase")
    balance = _money(payload.get("balance"))
    reference = _text(purchase.get("id"), 64)
    state = str(purchase.get("status") or "")
    if status == 202 or state == "pending":
        return _unknown("the purchase is still pending", reference=reference)
    if state == "succeeded" and service is not None:
        slip = pointy_services.receipt(purchase, service)
        if slip is None:
            return _unknown("bought, but its receipt was not read back yet", reference=reference)
        return RechargeResult(
            ok=True,
            reference=reference,
            balance_after=balance,
            receipt=slip,
            actual_cost=_money(purchase.get("unit_price")),
        )
    if state == "succeeded":
        code_row = _first_code(purchase)
        if code_row is None:
            return _unknown("bought, but its code was not read back yet", reference=reference)
        return RechargeResult(
            ok=True,
            reference=reference,
            balance_after=balance,
            receipt=_receipt(purchase, code_row, words),
            actual_cost=_money(purchase.get("unit_price")),
        )
    if state == "failed":
        # A replay of a purchase that failed and was refunded.
        return RechargeResult(
            ok=False,
            balance_after=balance,
            error_code=_FAILED_PURCHASE_CODES.get(
                str(purchase.get("error_code") or ""), ERROR_PROVIDER_ERROR
            ),
            error_detail=_failure_detail(purchase),
        )
    return _unknown(f"unrecognised purchase status {state!r}", reference=reference)


def _refused_purchase(exc: RelayControlError, words: dict) -> RechargeResult:
    """A purchase that did not answer ``2xx``.

    Definite only where nothing can have been bought: the request never reached
    the relay, or the relay itself said no in its own words. A ``5xx`` without
    them — a proxy in front of a relay that may be mid-purchase — is not proof.
    """
    status = exc.status_code
    if status is None:
        if exc.request_sent is False:
            return RechargeResult(ok=False, error_code=ERROR_UNREACHABLE, error_detail=str(exc))
        return _unknown(f"the purchase may have gone through: {exc}")
    body = _error_body(exc)
    code = str(body.get("code") or "")
    if status == 402:
        return RechargeResult(
            ok=False,
            error_code=ERROR_INSUFFICIENT_FLOAT,
            balance_after=_money(body.get("balance")),
            # A code word first, the shop's own figures after it: only a reader
            # who may see cost is given them (``base.without_figures``).
            error_detail=(
                f"insufficient_balance: voucher balance {body.get('balance')} "
                f"below {body.get('amount')}"
            ),
        )
    if status == 409:
        if code == "in_flight":
            # The same key is being bought right now: it may well succeed.
            return _unknown("in_flight")
        if code == "item_unavailable":
            return RechargeResult(ok=False, error_code=ERROR_OUT_OF_STOCK, error_detail=code)
        if code == "price_changed":
            # Cards and services alike: the relay's price rose above the ceiling
            # it was given. A code of its own, so the till can say so in Arabic.
            return RechargeResult(
                ok=False,
                error_code=ERROR_PRICE_CHANGED,
                error_detail=f"price_changed: the relay now charges {body.get('unit_price')}",
            )
        if code == "service_unavailable":
            # The relay sells no services right now (no supplier set up, no
            # exchange rate): nothing was held, and a shop cannot fix it.
            return RechargeResult(
                ok=False,
                error_code=ERROR_UNAVAILABLE,
                error_detail=": ".join(
                    part for part in (code, _text(body.get("reason"), 64)) if part
                ),
            )
        return RechargeResult(ok=False, error_code=ERROR_PROVIDER_ERROR, error_detail=code or "409")
    if status == 404:
        if code == "unknown_item" or pointy_services.refused_code(code) == ERROR_OUT_OF_STOCK:
            # The card, the network or the biller left the relay's list since
            # the till read it.
            return RechargeResult(ok=False, error_code=ERROR_OUT_OF_STOCK, error_detail=code)
        return RechargeResult(
            ok=False, error_code=ERROR_UNAVAILABLE, error_detail=code or "no voucher purchases here"
        )
    if status in (401, 403):
        return RechargeResult(
            ok=False, error_code=ERROR_UNAUTHORIZED, error_detail=code or str(status)
        )
    if status == 429:
        return RechargeResult(ok=False, error_code=ERROR_BUSY, error_detail=code or "rate_limited")
    if status == 502 and code in _SUPPLIER_REFUSALS:
        purchase = body.get("purchase") if isinstance(body.get("purchase"), dict) else {}
        if _may_still_happen(purchase):
            # The relay named a refusal but its own purchase says it is held or
            # done: the refusal is not proof of anything.
            return _unknown(f"the relay refused ({code}) but holds the purchase")
        return RechargeResult(
            ok=False,
            error_code=_SUPPLIER_REFUSALS[code],
            balance_after=_money(body.get("balance")),
            error_detail=_failure_detail(purchase) or code,
        )
    if status == 503 and code in (
        "vouchers_unconfigured",
        "services_unconfigured",
        "services_unpriced",
    ):
        return RechargeResult(ok=False, error_code=ERROR_UNAVAILABLE, error_detail=code)
    if 400 <= status < 500:
        # The relay refused the request: as malformed (``422``) or for a reason
        # about this one thing — a number it cannot reach, an amount it does not
        # take — or for one this build does not know. Nothing was held.
        return RechargeResult(
            ok=False,
            error_code=pointy_services.refused_code(code) or ERROR_UNEXPECTED,
            error_detail=code or f"answered {status}",
        )
    return _unknown(f"the relay answered {status} {code}".strip())


def _may_still_happen(purchase: dict) -> bool:
    """Whether a purchase the relay attached to a refusal is anything but failed.

    A failed purchase is refunded — that is what makes a supplier refusal
    definite. One the relay still holds, or has already completed, is not.
    """
    return purchase.get("held") is True or str(purchase.get("status") or "") in (
        "pending",
        "succeeded",
    )


def _unknown(detail: str, *, reference: str = "") -> RechargeResult:
    return RechargeResult(
        ok=False,
        indeterminate=True,
        reference=reference,
        error_code=ERROR_INDETERMINATE,
        error_detail=detail,
    )


def _masked(result: RechargeResult) -> RechargeResult:
    """``result`` with no customer number in its error detail.

    What a service order was sent for is a phone number or an account; the
    relay's words and a transport error may repeat it, and the detail is
    stored on the fulfillment and recorded by telemetry.
    """
    if not result.error_detail:
        return result
    return replace(result, error_detail=mask_numbers(result.error_detail))


def _first_code(purchase: dict) -> dict | None:
    """The card's code, or ``None`` while the relay could not read it back."""
    if purchase.get("codes_pending") is True:
        return None
    for row in purchase.get("codes") or ():
        if isinstance(row, dict) and _text(row.get("code")):
            return row
    return None


def _receipt(purchase: dict, code_row: dict, words: dict) -> dict:
    """What the fulfillment keeps, and the slip prints (``printed``)."""
    printed = {
        "brand": words.get("brand") or "",
        "product": words.get("product") or _text(purchase.get("name"), 160),
        "code": _text(code_row.get("code"), 200),
        "serial": _text(code_row.get("serial"), 200),
        "instructions": words.get("instructions") or "",
    }
    receipt = {
        "purchase_id": _text(purchase.get("id"), 64),
        "item": _text(purchase.get("item"), 64),
        "unit_price": _text(purchase.get("unit_price"), 32),
        "printed": {key: value for key, value in printed.items() if value},
    }
    if purchase.get("test_mode") is True:
        # Bought from the relay's test supplier: the code is not a real card, and
        # the slip says so, as a service's does.
        receipt["test_mode"] = True
        receipt["printed"]["notice"] = pointy_services.NOTICE_TEST_CARD
    return receipt


def _failure_detail(purchase: dict) -> str:
    code = _text(purchase.get("error_code"), 64)
    detail = _text(purchase.get("error_detail"), 200)
    return ": ".join(part for part in (code, detail) if part)


def _read_refusal(exc: RelayControlError) -> tuple[str, str]:
    """A failed READ in the driver vocabulary. Reads change nothing, so every
    failure is simply what it says."""
    status = exc.status_code
    if status is None:
        return ERROR_UNREACHABLE, str(exc)
    code = str(_error_body(exc).get("code") or "")
    if status in (401, 403):
        return ERROR_UNAUTHORIZED, code or str(status)
    if status == 503 and code == "vouchers_unconfigured":
        return ERROR_UNAVAILABLE, code
    if status == 404:
        return ERROR_NOT_FOUND, code or "404"
    if status >= 500:
        return ERROR_UNREACHABLE, code or str(status)
    return ERROR_PROVIDER_ERROR, code or str(status)


def _error_body(exc: RelayControlError) -> dict:
    return _json_object(exc.body) or {}
