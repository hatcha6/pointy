"""Currency, rate, and repricing endpoints.

The read endpoints are deliberately chatty about provenance: a client asking
"what is the dollar worth" gets back the rate *and* where it came from, how old
it is, and whether it is the settlement series the shop asked for. The apps are
expected to surface all three, because a rate shown without its age is the same
mistake as a total shown without its currency.
"""

from __future__ import annotations

from django.utils import timezone
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.catalog.models import Product
from apps.catalog.pricing import apply_reprice, reprice_preview
from apps.core.models import ShopSettings
from apps.core.permissions import HasPointyPermission

from . import currencies as ref
from .models import Currency, ExchangeRate
from .rates import rate_on
from .serializers import (
    ApplyRepriceSerializer,
    CurrencySerializer,
    ExchangeRateSerializer,
    ManualRateSerializer,
    PriceProposalSerializer,
    ResolvedRateSerializer,
)
from .services import record_manual_rate, sync_exchange_rates


class CurrencyViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    viewsets.GenericViewSet,
):
    """The currency registry. Read-mostly; enabling and hiding is the only edit.

    Deliberately no create/destroy: currencies are reference data seeded from
    the eight pairs the feed publishes, and a currency row may be referenced by a
    product's price sheet or by a rate a document froze — deleting one would
    orphan history.
    """

    queryset = Currency.objects.all()
    serializer_class = CurrencySerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("fx.view_currency",),
        "retrieve": ("fx.view_currency",),
        "update": ("fx.change_currency",),
        "partial_update": ("fx.change_currency",),
    }
    filterset_fields = ("is_enabled",)
    ordering_fields = ("display_order", "code")


class ExchangeRateViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    """Published and typed rates.

    List is history, not state: rows are never edited or deleted, so this is an
    audit trail of what the shop knew and when. ``current`` is the resolved
    answer the apps actually price off.
    """

    queryset = ExchangeRate.objects.select_related(
        "from_currency", "to_currency"
    ).all()
    serializer_class = ExchangeRateSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("fx.view_exchangerate",),
        "retrieve": ("fx.view_exchangerate",),
        "current": ("fx.view_exchangerate",),
        "manual": ("fx.add_exchangerate",),
        "sync": ("fx.add_exchangerate",),
    }
    filterset_fields = ("from_currency", "to_currency", "instrument", "source")
    ordering_fields = ("effective_at", "created_at")

    @action(detail=False, methods=["get"])
    def current(self, request):
        """The rate the shop would price at right now, per enabled currency.

        Returns one entry per foreign currency, each carrying its provenance so
        the UI can flag a stale or substituted series rather than presenting a
        bare number as fact.
        """
        settings_row = ShopSettings.load()
        base = settings_row.currency_code
        codes = (
            Currency.objects.filter(is_enabled=True)
            .exclude(pk=base)
            .values_list("pk", flat=True)
        )
        resolved = []
        for code in codes:
            found = rate_on(code, base)
            if found is not None:
                resolved.append(found)
        payload = ResolvedRateSerializer(
            resolved,
            many=True,
            context={"staleness_hours": settings_row.fx_rate_staleness_hours},
        ).data
        return Response(
            {
                "base_code": base,
                # The master switch. A shop with this off is single-currency and
                # must never be shown a currency picker — the clients gate their
                # whole FX surface on it.
                "fx_enabled": settings_row.fx_enabled,
                "instrument": settings_row.fx_instrument,
                "bank_code": settings_row.fx_bank_code,
                "staleness_hours": settings_row.fx_rate_staleness_hours,
                "rates": payload,
            }
        )

    @action(detail=False, methods=["post"])
    def manual(self, request):
        """Record a rate the owner typed. Outranks the feed at the same instant."""
        serializer = ManualRateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        row = record_manual_rate(
            entered_by=request.user, **serializer.validated_data
        )
        return Response(
            ExchangeRateSerializer(row).data, status=status.HTTP_201_CREATED
        )

    @action(detail=False, methods=["post"])
    def sync(self, request):
        """Pull from the relay now, rather than waiting for the hourly beat."""
        return Response(sync_exchange_rates())


class RepricingViewSet(viewsets.GenericViewSet):
    """What a rate move would do to the catalogue, and applying it.

    Two steps on purpose. A repricing that happened automatically would change a
    shelf price between a customer asking and paying; a repricing that happened
    without a preview would be a number the owner never agreed to.
    """

    queryset = Product.objects.none()
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "preview": ("catalog.change_product",),
        "apply": ("catalog.change_product",),
    }

    @action(detail=False, methods=["get"])
    def preview(self, request):
        include_unchanged = str(
            request.query_params.get("include_unchanged", "")
        ).lower() in ("1", "true", "yes")
        # Pin the instant rather than letting each rate lookup call now()
        # separately, and hand it back so the client can echo it on apply. That
        # is what makes "what you were shown is what gets written" true across
        # the two requests, not just within one.
        resolved_at = timezone.now()
        proposals = reprice_preview(
            at=resolved_at, include_unchanged=include_unchanged
        )
        return Response(
            {
                "count": len(proposals),
                "resolved_at": resolved_at,
                "proposals": PriceProposalSerializer(proposals, many=True).data,
            }
        )

    @action(detail=False, methods=["post"])
    def apply(self, request):
        serializer = ApplyRepriceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        wanted = {
            (str(item.get("kind")), int(item.get("target_id")))
            for item in serializer.validated_data["targets"]
            if item.get("kind") and str(item.get("target_id", "")).isdigit()
        }
        # Re-derive at the instant the client was shown, so what was previewed
        # is what is written even if a newer rate landed in between. A client
        # that omits it is served the current rates — correct, but it is the
        # echoed instant that makes the confirmation dialog binding.
        proposals = [
            proposal
            for proposal in reprice_preview(
                at=serializer.validated_data.get("resolved_at")
            )
            if (proposal.kind, proposal.target_id) in wanted
        ]
        written = apply_reprice(proposals)
        return Response({"repriced": written})
