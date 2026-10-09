"""Owner/manager endpoints for «أسعار كروت دفتر» (see :mod:`.pricing_api`)."""

from __future__ import annotations

from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission

from . import pricing_api

MANAGE = ("integrations.manage_integrations",)


class _Base(APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]


class PricingView(_Base):
    permission_map = {"GET": MANAGE, "PUT": MANAGE}

    def get(self, request):
        return Response(pricing_api.read())

    def put(self, request):
        return Response(pricing_api.write(request.data))


class PricingCardsView(_Base):
    permission_map = {"GET": MANAGE}

    def get(self, request):
        return Response(pricing_api.cards(request.query_params))


class PricingCardView(_Base):
    permission_map = {"PUT": MANAGE}

    def put(self, request, variant_id: int):
        return Response(pricing_api.set_card(variant_id, request.data))


class PricingCardsBulkView(_Base):
    permission_map = {"POST": MANAGE}

    def post(self, request):
        return Response(pricing_api.bulk_cards(request.data))
