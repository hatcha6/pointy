"""The Shop Settings → Integrations API.

Shaped around providers rather than rows: the client asks for the catalog and
gets every provider back, configured or not, so the screen never has to know
which ones exist. Credentials are addressed by provider key for the same
reason — there is no account id to learn before you can save one.
"""

from __future__ import annotations

from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission

from . import catalog
from . import recharge
from .models import IntegrationAccount, IntegrationFulfillment
from .providers import provider_for
from .providers.base import ERROR_NOT_CONFIGURED, ERROR_NOT_FOUND, ERROR_UNAVAILABLE
from . import float_ledger
from .provisioning import service_variant_for
from .serializers import (
    IntegrationAccountWriteSerializer,
    OptionPriceWriteSerializer,
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
    status_payload,
)
from .services import (
    accounts_by_provider,
    probe_account,
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
        if "base_url" in data:
            account.base_url = data["base_url"].strip()
        if "username" in data:
            account.username = data["username"].strip()
        if "is_active" in data:
            account.is_active = data["is_active"]
        # Absent or blank means "keep what is stored" — the client cannot read
        # the password back, so it cannot round-trip one it never received.
        password = data.get("password")
        if password:
            account.set_secret(catalog.FIELD_PASSWORD, password)
        account.save()

        return Response(_provider_payload(spec))

    def delete(self, request, provider: str):
        spec = catalog.spec_for(provider)
        if spec is None:
            return Response(
                {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
            )
        IntegrationAccount.objects.filter(provider=provider).delete()
        return Response(_provider_payload(spec))


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

        result = provider_for(account).lookup(request.query_params.get("card_no", ""))
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
        lookup = driver.lookup(card_no)
        if not lookup.ok:
            return Response(
                {
                    "ok": False,
                    "error_code": lookup.error_code,
                    "error_detail": lookup.error_detail,
                }
            )

        if lookup.is_ambiguous:
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

        # Prices are quoted live and never cached — see RechargeOption.
        offers = driver.offers(card_no)
        # Teach Shop Settings what there is to price. The ladder is per-card,
        # so a real lookup is the only place this catalog can come from.
        record_seen_offers(account, offers.options)
        # The detail modal carries what the list row does not — the device,
        # the monthly price, and this subscriber's lifetime with the provider.
        profile = driver.subscriber_profile(card_no)
        subscriber = record_subscriber(
            account, profile.profile if profile.ok else None, card=lookup.card
        )
        # One query for the shop's whole price list rather than one per option.
        prices = account.option_price_map()
        return Response(
            {
                "ok": True,
                "card": card_payload(lookup.card),
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
