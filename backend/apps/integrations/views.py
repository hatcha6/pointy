"""The Shop Settings → Integrations API.

Shaped around providers rather than rows: the client asks for the catalog and
gets every provider back, configured or not, so the screen never has to know
which ones exist. Credentials are addressed by provider key for the same
reason — there is no account id to learn before you can save one.
"""

from __future__ import annotations

import base64
from dataclasses import replace

from rest_framework import status
from rest_framework.filters import SearchFilter
from rest_framework.generics import ListAPIView
from rest_framework.pagination import CursorPagination
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission

from . import catalog
from . import recharge
from .models import IntegrationAccount, IntegrationFulfillment, IntegrationSearch
from .providers import provider_for
from .providers.base import (
    ERROR_NOT_CONFIGURED,
    ERROR_NOT_FOUND,
    ERROR_UNAVAILABLE,
    in_parallel,
)
from . import float_ledger
from .provisioning import service_variant_for
from .serializers import (
    IntegrationAccountWriteSerializer,
    OptionPriceWriteSerializer,
    ProfileChoiceSerializer,
    VerificationConfirmSerializer,
    VerificationSendSerializer,
    profile_payload,
    SubscriberWriteSerializer,
    TopUpWriteSerializer,
    ProviderSerializer,
    card_payload,
    open_amount_payload,
    charge_payload,
    offer_payload,
    float_payload,
    option_price_payload,
    subscriber_payload,
    purchase_payload,
    search_payload,
    status_payload,
)
from .services import (
    accounts_by_provider,
    probe_account,
    record_search,
    record_seen_offers,
    record_subscriber,
)

# A till reads one page at a time; the provider paginates server-side and a
# cashier is never scrolling hundreds of rows on a receipt printer's screen.
DEFAULT_PAGE_SIZE = 10
MAX_PAGE_SIZE = 50

MANAGE = ("integrations.manage_integrations",)
USE = ("integrations.use_integrations",)
TOP_UP = "integrations.record_integration_topup"


def _catalog_payload() -> dict:
    accounts = accounts_by_provider()
    return {
        "providers": [
            ProviderSerializer.payload(spec, accounts.get(spec.key))
            for spec in catalog.PROVIDERS
        ]
    }


def _apply_settings(account, spec, incoming: dict) -> dict:
    """Merge declared settings onto an account. Returns what it refused.

    Only keys the provider declares are touched, so nothing a client invents
    can reach ``config`` — it is a JSONField, and an endpoint that wrote it
    verbatim would be an open door into the account's own storage.
    """
    rejected = {}
    config = dict(account.config or {})
    for key, value in incoming.items():
        declared = spec.setting(key)
        if declared is None:
            rejected[key] = "unknown setting"
            continue
        cleaned = declared.clean(value)
        if cleaned is None:
            rejected[key] = "out of range"
            continue
        config[key] = cleaned
    if not rejected:
        account.config = config
    return rejected


def _provider_payload(spec: catalog.ProviderSpec) -> dict:
    account = IntegrationAccount.objects.filter(provider=spec.key).first()
    return ProviderSerializer.payload(spec, account)


class IntegrationCatalogView(APIView):
    """GET the whole catalog with this shop's accounts merged in."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": MANAGE}

    def get(self, request):
        return Response(_catalog_payload())


class IntegrationAccountView(APIView):
    """Save or clear the credentials for one provider."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"PUT": MANAGE, "DELETE": MANAGE}

    def put(self, request, provider: str):
        spec = catalog.spec_for(provider)
        if spec is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        # A planned provider has no driver, so storing a password for it would
        # only be a credential sitting in the database doing nothing.
        if not spec.is_available:
            return Response(
                {"detail": "provider not available", "blocked_reason": spec.blocked_reason},
                status=status.HTTP_409_CONFLICT,
            )

        serializer = IntegrationAccountWriteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        account, _ = IntegrationAccount.objects.get_or_create(provider=provider)
        previous_login = (account.username, account.password, account.resolved_base_url())
        if "base_url" in data:
            account.base_url = data["base_url"].strip()
        if "username" in data:
            account.username = data["username"].strip()
        if "is_active" in data:
            account.is_active = data["is_active"]
        # Absent or blank means "keep what is stored" — the client cannot read
        # a secret back, so it cannot round-trip one it never received. Every
        # secret the provider declares is handled the same way: the password,
        # and for a provider that has one, the purchase PIN.
        for field in spec.secret_fields:
            value = data.get(field)
            if value:
                account.set_secret(field, value)
        # A login a driver kept (Qareeb's bearer token) belongs to the
        # credentials that made it. New ones make it somebody else's.
        if (account.username, account.password, account.resolved_base_url()) != previous_login:
            account.forget_session()

        # Settings are the shop's commercial arrangement, not credentials, so
        # a bad one is refused loudly rather than quietly ignored: a shop that
        # types its commission wrong and is told nothing would book the wrong
        # margin on every sale until somebody noticed in a profit report.
        rejected = _apply_settings(account, spec, data.get("settings") or {})
        if rejected:
            return Response(
                {"settings": rejected}, status=status.HTTP_400_BAD_REQUEST
            )
        account.save()
        _after_account_change(account)

        return Response(_provider_payload(spec))

    def delete(self, request, provider: str):
        spec = catalog.spec_for(provider)
        if spec is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        account = IntegrationAccount.objects.filter(provider=provider).first()
        if account is not None:
            disconnect_account(account)
        return Response(_provider_payload(spec))


def disconnect_account(account) -> None:
    """Forget the credentials; keep whatever the shop's history hangs on.

    An account that ever sold anything is referenced by those sales
    (``IntegrationFulfillment.account`` is PROTECT) and by its float's money
    account, so deleting it would fail — and should: an invoice must still say
    which provider performed its top-up. Such an account is emptied instead:
    no username, no secrets, switched off. One that never did anything goes
    entirely. Either way its cards leave the till first.
    """
    from . import vouchers

    if vouchers.sells_vouchers(account):
        vouchers.withdraw_shelf(account)
    has_history = account.fulfillments.exists() or account.money_account_id is not None
    if not has_history:
        account.delete()
        return
    account.username = ""
    account.secrets_encrypted = ""
    account.is_active = False
    account.last_error = ""
    account.last_error_code = ""
    account.last_error_at = None
    account.save()


def _after_account_change(account) -> None:
    """Bring a voucher provider's shelf in line with an account that just changed.

    Switched off or incomplete: its cards leave the till now, not at the next
    sweep. Otherwise a full read is queued, so a freshly connected shop sees
    its cards within seconds rather than at the next sweep.
    """
    from . import vouchers

    if not vouchers.sells_vouchers(account):
        return
    if not account.is_active or not account.is_configured:
        vouchers.withdraw_shelf(account)
        return
    schedule_voucher_sync(account)


def schedule_voucher_sync(account) -> None:
    from apps.core.dispatch import enqueue_best_effort

    enqueue_best_effort("integrations.sync_voucher_catalog", account.pk)


class IntegrationProbeView(APIView):
    """Test the stored credentials now and report what came back."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": MANAGE}

    def post(self, request, provider: str):
        spec = catalog.spec_for(provider)
        if spec is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        account = IntegrationAccount.objects.filter(provider=provider).first()
        if account is None:
            return Response(
                {
                    "ok": False,
                    "error_code": ERROR_NOT_CONFIGURED,
                    "provider": _provider_payload(spec),
                }
            )
        result = probe_account(account)
        if result.ok:
            _after_account_change(account)
        # A failed probe is a fact about the provider, not a failure of this
        # request: 200 with ok=false, so the client renders the reason instead
        # of a generic error toast.
        return Response(
            {
                "ok": result.ok,
                "error_code": result.error_code,
                "error_detail": result.error_detail,
                "provider": _provider_payload(spec),
            }
        )


class IntegrationLookupView(APIView):
    """Look one subscriber card up — the read the till will lean on later."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request, provider: str):
        spec = catalog.spec_for(provider)
        if spec is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        account = IntegrationAccount.objects.filter(
            provider=provider, is_active=True
        ).first()
        if account is None or not account.is_configured:
            return Response({"ok": False, "error_code": ERROR_NOT_CONFIGURED})
        if not spec.is_available:
            return Response({"ok": False, "error_code": ERROR_UNAVAILABLE})

        result = provider_for(account).lookup(
            request.query_params.get("card_no", ""),
            search_by=request.query_params.get("search_by", ""),
        )
        return Response(
            {
                "ok": result.ok,
                "error_code": result.error_code,
                "error_detail": result.error_detail,
                # Set only when the search matched exactly one line.
                "card": card_payload(result.card),
                # Every line the term matched. One phone number can hold
                # several, so this is the list and ``card`` is the shortcut.
                "candidates": [card_payload(c) for c in result.candidates],
            }
        )


def _usable_account(provider: str):
    """``(account, spec, error_code)`` — the account a till may actually use."""
    spec = catalog.spec_for(provider)
    if spec is None:
        return None, None, "unknown_provider"
    if not spec.is_available:
        return None, spec, ERROR_UNAVAILABLE
    account = IntegrationAccount.objects.filter(
        provider=provider, is_active=True
    ).first()
    if account is None or not account.is_configured:
        return None, spec, ERROR_NOT_CONFIGURED
    return account, spec, ""


def _service_variant_payload(provider: str) -> dict:
    variant = service_variant_for(provider)
    return {
        "id": variant.id,
        "product_id": variant.product_id,
        "sku": variant.sku,
        "name": variant.product.name,
    }


def _with_subscriber_balance(card, profile):
    """The card, carrying the subscriber's own balance wherever it was read.

    LNET prints a line's money on the search row, so its card already has it.
    HD Box keeps a card's balance on the detail page instead — which the card
    view reads anyway, beside the offers — so without this the one provider
    whose balance was fetched would be the one whose till never showed it.

    Only ever this request's own reads. A profile that failed leaves the card
    blank rather than falling back to a balance remembered from an earlier
    lookup: a stale figure shown as the customer's credit is worse than none.
    """
    if card.card_balance is not None or not profile.ok or profile.profile is None:
        return card
    if profile.profile.card_balance is None:
        return card
    return replace(card, card_balance=profile.profile.card_balance)


def _page_bounds(request) -> tuple[int, int]:
    try:
        limit = int(request.query_params.get("limit", DEFAULT_PAGE_SIZE))
    except (TypeError, ValueError):
        limit = DEFAULT_PAGE_SIZE
    try:
        offset = int(request.query_params.get("offset", 0))
    except (TypeError, ValueError):
        offset = 0
    return max(1, min(limit, MAX_PAGE_SIZE)), max(0, offset)


class IntegrationCardView(APIView):
    """Everything the till needs about one subscriber, in a single call.

    The card, what can be bought for it at today's prices, and the variant a
    cart line should point at. One round trip because this runs with a customer
    standing at the counter, and three sequential provider logins is a wait a
    cashier can feel.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request, provider: str):
        account, spec, error = _usable_account(provider)
        if error == "unknown_provider":
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if account is None:
            return Response({"ok": False, "error_code": error})

        card_no = (request.query_params.get("card_no") or "").strip()
        if not card_no:
            return Response({"ok": False, "error_code": ERROR_NOT_FOUND})

        driver = provider_for(account)
        # What the till says this number IS. A phone number and a contract
        # number are both digits, so the portal has to be asked the right way
        # or asked twice; the picker beside the search box is what turns the
        # ordinary lookup into a single round trip.
        search_by = request.query_params.get("search_by", "")
        lookup = driver.lookup(card_no, search_by=search_by)
        if not lookup.ok:
            return Response(
                {
                    "ok": False,
                    "error_code": lookup.error_code,
                    "error_detail": lookup.error_detail,
                }
            )

        if lookup.is_ambiguous:
            # Still a search that worked: it found the household, and running
            # it again from the history is how the till gets back to the choice.
            record_search(account, term=card_no, search_by=search_by, lookup=lookup)
            # One phone number, several lines. Quoting the first would offer a
            # cashier a top-up for somebody's dead second line while the one
            # the customer came in about stays expired — so this answers with
            # the choice instead, and the till asks before anything is priced.
            return Response(
                {
                    "ok": True,
                    "needs_selection": True,
                    "candidates": [card_payload(c) for c in lookup.candidates],
                    "service_variant": _service_variant_payload(provider),
                    "currency": spec.currency,
                    "balance": account.balance,
                    "balance_at": account.balance_at,
                }
            )

        # The identifier the customer typed and the one the line is actually
        # KNOWN by are not always the same string — a cashier searches LNET by
        # phone number, and the line's own identifier is a username the search
        # merely found. From here on, use what lookup() actually resolved
        # rather than what was typed: for HD Box the two already coincide, but
        # for LNET, offers()/subscriber_profile() require an EXACT match on
        # whatever they are given, and matching a phone number against a
        # username always fails — silently emptying the offer list for
        # exactly the search a till does most, a phone lookup, and leaving
        # nothing there for the cashier to sell. Passing the resolved card
        # also lets both calls skip searching all over again for a line this
        # request already found.
        resolved_card_no = lookup.card.card_no

        # Prices are quoted live and never cached — see RechargeOption. The
        # offer ladder and the subscriber's detail page are two different
        # pages about the same line, and NEITHER needs the other's answer:
        # read one after the other they cost a cashier both waits, read
        # together they cost the slower one. Each arm builds its own driver
        # because a session cannot be shared across threads — see
        # ``in_parallel``; the session cache means the second instance still
        # logs in nowhere.
        offers, profile = in_parallel(
            [
                # On the driver that just did the lookup, so this rides the
                # connection that is already open and warm rather than paying
                # another TLS handshake for the same host.
                lambda: driver.offers(resolved_card_no, resolved=lookup.card),
                # The detail modal carries what the list row does not — the
                # device, the monthly price, and this subscriber's lifetime
                # with the provider. Its own driver, because the one above is
                # busy on the same socket.
                lambda: provider_for(account).subscriber_profile(
                    resolved_card_no, resolved=lookup.card
                ),
            ]
        )
        # Teach Shop Settings what there is to price. The ladder is per-card,
        # so a real lookup is the only place this catalog can come from. Back
        # on the request's own thread: the workers above touch no database.
        record_seen_offers(account, offers.options)
        subscriber = record_subscriber(
            account, profile.profile if profile.ok else None, card=lookup.card
        )
        record_search(
            account,
            term=card_no,
            search_by=search_by,
            lookup=lookup,
            subscriber=subscriber,
        )
        # One query for the shop's whole price list rather than one per option.
        prices = account.option_price_map()
        return Response(
            {
                "ok": True,
                "card": card_payload(_with_subscriber_balance(lookup.card, profile)),
                "subscriber": subscriber_payload(subscriber),
                "offers": [
                    offer_payload(option, account, prices=prices)
                    for option in offers.options
                ],
                "offers_error_code": "" if offers.ok else offers.error_code,
                # When set, the listed offers are shortcuts and the provider
                # will take any amount in this range — the till must give the
                # cashier somewhere to type one, or it is less capable than
                # the portal the shop already uses.
                "open_amount": open_amount_payload(offers.open_amount, account),
                # False here, but always present so the till has one shape to
                # read rather than two.
                "needs_selection": False,
                # Which history tabs this provider can actually answer. LNET
                # keeps no state log, and a tab that always errors reads to a
                # cashier as the provider being down.
                "history_kinds": list(driver.history_kinds),
                # The cart line must point at a real variant, so the till is
                # given the whole identity rather than just an id it would
                # have to go and look up mid-sale.
                "service_variant": _service_variant_payload(provider),
                "currency": spec.currency,
                # The float, so the till can warn before a cashier sells
                # something the agency cannot pay for. ``balance_at`` says how
                # old the figure is: it is refreshed by every probe and by
                # every successful charge, not read live on each lookup.
                "balance": account.balance,
                "balance_at": account.balance_at,
            }
        )


class RecentSearchPagination(CursorPagination):
    """Newest search first, each page anchored to the last row the till saw.

    This list is written to while it is being read: a search at any till lands
    at its head, and a repeated search jumps back there. Page numbers would
    hand a cashier scrolling it the same row twice or skip one outright; a
    cursor can do neither. A row that jumps to the head mid-scroll is simply
    not repeated further down — it is at the top on the next open.
    """

    ordering = ("-last_searched_at", "-id")
    page_size = 20
    page_size_query_param = "page_size"
    max_page_size = 100


class IntegrationSearchesView(ListAPIView):
    """The searches a till ran against one provider that found something.

    What the recharge screen opens on instead of an empty box: the customers
    this shop actually serves, newest first. ``search`` narrows it as the
    cashier types — by the number typed, the line it found, or the name the
    shop gave the card.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}
    pagination_class = RecentSearchPagination
    # Only the text filter: the project-wide defaults include an ordering
    # filter that would fight the cursor's fixed order.
    filter_backends = [SearchFilter]
    search_fields = [
        "term",
        "card_no",
        "holder_name",
        "subscriber__display_name",
        "subscriber__customer__full_name",
    ]

    def get_queryset(self):
        account_id = (
            IntegrationAccount.objects.filter(provider=self.kwargs["provider"])
            .values_list("id", flat=True)
            .first()
        )
        if account_id is None:
            return IntegrationSearch.objects.none()
        return IntegrationSearch.objects.filter(account_id=account_id).select_related(
            "subscriber__customer"
        )

    def list(self, request, *args, **kwargs):
        if catalog.spec_for(self.kwargs["provider"]) is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        page = self.paginate_queryset(self.filter_queryset(self.get_queryset()))
        return self.get_paginated_response([search_payload(row) for row in page])


class IntegrationHistoryView(APIView):
    """A page of a subscriber's history — purchases, or state changes.

    Paginated against the provider, not fetched whole and sliced here: the
    provider counts for us, and a card with four years of renewals should not
    cost four years of rows to show ten.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request, provider: str):
        account, _spec, error = _usable_account(provider)
        if error == "unknown_provider":
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if account is None:
            return Response({"ok": False, "error_code": error})

        card_no = (request.query_params.get("card_no") or "").strip()
        kind = (request.query_params.get("kind") or "purchases").strip()
        limit, offset = _page_bounds(request)

        driver = provider_for(account)
        if kind == "statuses":
            result = driver.status_history(card_no, limit=limit, offset=offset)
            entries = [status_payload(entry) for entry in result.statuses]
        else:
            kind = "purchases"
            result = driver.purchase_history(card_no, limit=limit, offset=offset)
            entries = [purchase_payload(entry) for entry in result.purchases]

        return Response(
            {
                "ok": result.ok,
                "error_code": result.error_code,
                "error_detail": result.error_detail,
                "kind": kind,
                "total": result.total,
                "limit": limit,
                "offset": offset,
                "entries": entries,
            }
        )


class IntegrationPricesView(APIView):
    """The owner's retail price list for one provider.

    Separate from the account endpoint because it is a different job done by a
    different person at a different time: connecting an account is setup, and
    pricing is a decision the owner revisits whenever the provider moves its
    own numbers.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": MANAGE, "PUT": MANAGE}

    def _account(self, provider: str):
        spec = catalog.spec_for(provider)
        if spec is None:
            return None, None
        return IntegrationAccount.objects.filter(provider=provider).first(), spec

    def get(self, request, provider: str):
        account, spec = self._account(provider)
        if spec is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if account is None:
            return Response({"currency": spec.currency, "options": []})
        return Response(
            {
                "currency": spec.currency,
                "markup_kind": account.markup_kind,
                "markup_value": account.markup_value,
                "options": [
                    option_price_payload(row)
                    for row in account.option_prices.all()
                ],
            }
        )

    def put(self, request, provider: str):
        account, spec = self._account(provider)
        if spec is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if account is None:
            return Response(
                {"detail": "provider not configured"}, status=status.HTTP_409_CONFLICT
            )

        serializer = OptionPriceWriteSerializer(
            data=request.data.get("prices", []), many=True
        )
        serializer.is_valid(raise_exception=True)

        # Only options the shop has actually been quoted can be priced — a
        # code nobody has seen is a typo, not a product.
        known = {row.option_code: row for row in account.option_prices.all()}
        unknown = [
            item["option_code"]
            for item in serializer.validated_data
            if item["option_code"] not in known
        ]
        if unknown:
            return Response(
                {"detail": "unknown options", "option_codes": unknown},
                status=status.HTTP_400_BAD_REQUEST,
            )

        for item in serializer.validated_data:
            row = known[item["option_code"]]
            row.price = item["price"]
            row.save(update_fields=["price", "last_seen_at"])

        return self.get(request, provider)


class IntegrationFloatView(APIView):
    """The provider float: what is in it, and putting more in.

    A top-up is recorded as a move between the shop's own places (cash or
    bank → the float), not as an expense: the money has not been spent, it has
    been relocated. It becomes cost only when a top-up is actually performed,
    and that cost already rides on the order line that sold it.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        """Either right opens this screen.

        An owner configuring the provider reaches it from Shop Settings; the
        member of staff who actually paid reaches it from Expenses. Reported
        as the top-up right when neither is held, because that is the one
        worth granting.
        """
        for permission in (TOP_UP, *MANAGE):
            if request.user.has_perm(permission):
                return [permission]
        return [TOP_UP]

    def _account(self, provider: str):
        if catalog.spec_for(provider) is None:
            return None, False
        return IntegrationAccount.objects.filter(provider=provider).first(), True

    def get(self, request, provider: str):
        account, known = self._account(provider)
        if not known:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if account is None:
            return Response({"detail": "provider not configured"}, status=409)
        return Response(float_payload(account))

    def post(self, request, provider: str):
        account, known = self._account(provider)
        if not known:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if account is None:
            return Response({"detail": "provider not configured"}, status=409)

        serializer = TopUpWriteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        from_account = None
        raw_from = data.get("from_account")
        if raw_from:
            from apps.treasury.models import MoneyAccount

            from_account = MoneyAccount.objects.filter(
                pk=raw_from, is_active=True
            ).exclude(kind=MoneyAccount.Kind.PROVIDER).first()
            if from_account is None:
                # A float cannot fund a float, and a closed account cannot
                # fund anything — say which, rather than silently dropping it.
                return Response(
                    {"from_account": "not a usable source account"},
                    status=status.HTTP_400_BAD_REQUEST,
                )

        float_ledger.record_top_up(
            account,
            amount=data["amount"],
            from_account=from_account,
            moved_at=data.get("moved_at"),
            reference=data.get("reference", ""),
            note=data.get("note", ""),
            user=request.user,
        )
        return Response(float_payload(account), status=status.HTTP_201_CREATED)


class IntegrationSubscriberView(APIView):
    """Naming the person behind a card.

    Till work, not settings: the cashier is the one standing in front of the
    customer, and a card that stays anonymous is a renewal reminder nobody
    can send. It rides on ``use_integrations`` for that reason.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"PUT": USE}

    def put(self, request, provider: str, subscriber_ref: str):
        from .models import IntegrationSubscriber

        account, _spec, error = _usable_account(provider)
        if error == "unknown_provider":
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if account is None:
            return Response({"ok": False, "error_code": error})

        serializer = SubscriberWriteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        subscriber, _ = IntegrationSubscriber.objects.get_or_create(
            account=account,
            subscriber_ref=subscriber_ref,
            defaults={"provider": provider},
        )

        fields = []
        if "customer" in data:
            customer_id = data["customer"]
            if customer_id:
                from apps.customers.models import Customer

                if not Customer.objects.filter(pk=customer_id).exists():
                    return Response(
                        {"customer": "no such customer"},
                        status=status.HTTP_400_BAD_REQUEST,
                    )
            subscriber.customer_id = customer_id or None
            fields.append("customer")
        if "display_name" in data:
            subscriber.display_name = data["display_name"].strip()
            fields.append("display_name")
        if "note" in data:
            subscriber.note = data["note"].strip()
            fields.append("note")
        if fields:
            subscriber.save(update_fields=[*fields, "updated_at"])

        return Response(subscriber_payload(subscriber))


class IntegrationChargeView(APIView):
    """Perform the recharges a sale has already sold. Spends the float.

    Addressed by order, because that is how a till uses it: the sale completes,
    and the same screen immediately asks for its recharges to be performed. A
    single fulfillment can be named instead, which is how a cashier retries the
    one line a provider refused.

    Every write goes through :mod:`apps.integrations.recharge`, which allows a
    given line **one** attempt. This view therefore cannot double-charge by
    being called twice — a second call finds nothing claimable and says so.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": USE}

    def post(self, request):
        rows, error = self._targets(request.data)
        if error:
            return Response({"detail": error}, status=status.HTTP_400_BAD_REQUEST)

        results = [charge_payload(recharge.charge(row.pk, user=request.user)) for row in rows]
        accounts = {row.account_id for row in rows}
        balance = None
        if len(accounts) == 1:
            account = IntegrationAccount.objects.filter(pk=rows[0].account_id).first()
            balance = None if account is None else account.balance
        return Response({"results": results, "balance": balance})

    def _targets(self, data):
        """The fulfillments this call may attempt, oldest line first."""
        rows = IntegrationFulfillment.objects.select_related("account")
        fulfillment_id = data.get("fulfillment")
        order_id = data.get("order")
        if fulfillment_id:
            rows = rows.filter(pk=fulfillment_id)
        elif order_id:
            rows = rows.filter(order_line__order_id=order_id)
        else:
            return [], "name an order or a fulfillment"
        # Only what may still be attempted. Anything else is not an error —
        # a till that re-sends a completed sale should get "nothing to do".
        rows = rows.filter(status=IntegrationFulfillment.Status.PENDING)
        return list(rows.order_by("pk")), ""


# --- confirming a new device ------------------------------------------------------
def _verifiable_account(provider: str):
    """``(account, spec, response)`` — the account a verification step acts on."""
    spec = catalog.spec_for(provider)
    if spec is None:
        return None, None, Response(
            {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
        )
    account = IntegrationAccount.objects.filter(provider=provider).first()
    if account is None or not account.is_configured:
        return None, spec, Response({"ok": False, "error_code": ERROR_NOT_CONFIGURED})
    return account, spec, None


class IntegrationVerificationView(APIView):
    """Step one of trusting this Pointy: the picture a person has to read.

    Qareeb refuses a password login from a device it has not seen and wants a
    one-time code texted to the agency's phone instead — and asking for that
    code needs the text of a captcha picture. None of it can happen without
    the owner, so it is a short conversation in Shop Settings, done once.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": MANAGE}

    def post(self, request, provider: str):
        account, _spec, response = _verifiable_account(provider)
        if response is not None:
            return response
        challenge = provider_for(account).start_verification()
        if not challenge.ok:
            return Response(
                {
                    "ok": False,
                    "error_code": challenge.error_code,
                    "error_detail": challenge.error_detail,
                }
            )
        return Response(
            {
                "ok": True,
                "challenge_ref": challenge.challenge_ref,
                # Inline, so the till never has to reach the provider itself —
                # it may not be able to, and it has no business trying.
                "image": "data:{};base64,{}".format(
                    challenge.image_type or "image/png",
                    base64.b64encode(challenge.image).decode("ascii"),
                ),
                "help_text": challenge.help_text,
            }
        )


class IntegrationVerificationSendView(APIView):
    """Step two: the picture's text, and the provider texts the owner a code."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": MANAGE}

    def post(self, request, provider: str):
        account, _spec, response = _verifiable_account(provider)
        if response is not None:
            return response
        serializer = VerificationSendSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        result = provider_for(account).send_verification_code(
            serializer.validated_data["challenge_ref"],
            serializer.validated_data["answer"],
        )
        return Response(
            {
                "ok": result.ok,
                "expires_in": result.expires_in,
                "error_code": result.error_code,
                "error_detail": result.error_detail,
            }
        )


class IntegrationVerificationConfirmView(APIView):
    """Step three: the texted code. On success this device is trusted for good."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": MANAGE}

    def post(self, request, provider: str):
        account, spec, response = _verifiable_account(provider)
        if response is not None:
            return response
        serializer = VerificationConfirmSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        result = provider_for(account).confirm_verification(
            serializer.validated_data["code"]
        )
        if result.ok:
            account.refresh_from_db()
            # Straight to a real read, so the screen says "connected, float
            # 674.90" rather than leaving the owner to press Test.
            if probe_account(account).ok:
                _after_account_change(account)
        return Response(
            {
                "ok": result.ok,
                "error_code": result.error_code,
                "error_detail": result.error_detail,
                "provider": _provider_payload(spec),
            }
        )


# --- which profile Pointy buys as ----------------------------------------------------
class IntegrationProfilesView(APIView):
    """The profiles one login may act as, and which of them Pointy buys as.

    A Qareeb login can be a person and an employee of several shops at once,
    each with its own wallet; the owner chooses which one this shop's tills
    spend. The driver then refuses to buy while the login acts as any other
    (``profile_mismatch``) rather than paying from the wrong shop's float.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": MANAGE, "PUT": MANAGE}

    def _account(self, provider: str):
        spec = catalog.spec_for(provider)
        if spec is None:
            return None, None, Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        if catalog.CAPABILITY_PROFILES not in spec.capabilities:
            return None, spec, Response({"ok": False, "error_code": ERROR_UNAVAILABLE})
        account = IntegrationAccount.objects.filter(provider=provider).first()
        if account is None or not account.is_configured:
            return None, spec, Response({"ok": False, "error_code": ERROR_NOT_CONFIGURED})
        return account, spec, None

    def get(self, request, provider: str):
        account, _spec, response = self._account(provider)
        if response is not None:
            return response
        result = provider_for(account).profiles()
        chosen = str((account.config or {}).get("profile_id") or "")
        return Response(
            {
                "ok": result.ok,
                "error_code": result.error_code,
                "error_detail": result.error_detail,
                "chosen": chosen,
                "profiles": [
                    profile_payload(profile, chosen=chosen) for profile in result.profiles
                ],
            }
        )

    def put(self, request, provider: str):
        account, spec, response = self._account(provider)
        if response is not None:
            return response
        serializer = ProfileChoiceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        chosen = serializer.validated_data["profile_id"].strip()
        name = ""
        if chosen:
            result = provider_for(account).profiles()
            if not result.ok:
                return Response(
                    {
                        "ok": False,
                        "error_code": result.error_code,
                        "error_detail": result.error_detail,
                    }
                )
            match = next(
                (profile for profile in result.profiles if profile.profile_id == chosen),
                None,
            )
            if match is None:
                return Response(
                    {"profile_id": "not one of this login's profiles"},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            name = match.name
        config = dict(account.config or {})
        config["profile_id"] = chosen
        config["profile_name"] = name
        account.config = config
        account.save(update_fields=["config", "updated_at"])
        # Re-read the float as the chosen profile — or learn at once that the
        # login is acting as another one.
        probe_account(account)
        return Response({"ok": True, "provider": _provider_payload(spec)})


# --- the till's "is this card still in stock?" ------------------------------------
class IntegrationVoucherView(APIView):
    """One brand's cards as the provider has them right now.

    The till calls this the moment a cashier opens a card's picker, and draws
    the picker from what it already has while it waits — so a card that sold
    out since the last sweep disappears while the cashier is still choosing,
    and nothing about the tap ever waits on the provider. Shared between tills
    for under a minute (``vouchers.refresh_brand``).
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request, product_id: int):
        from . import vouchers
        from .models import IntegrationVoucherBrand

        brand = (
            IntegrationVoucherBrand.objects.select_related("account")
            .filter(product_id=product_id)
            .first()
        )
        if brand is None:
            return Response(
                {"detail": "not a provider's card"}, status=status.HTTP_404_NOT_FOUND
            )
        account, _spec, error = _usable_account(brand.account.provider)
        if account is None:
            return Response({"ok": False, "error_code": error})
        return Response({"ok": True, **vouchers.refresh_brand(account, brand)})
