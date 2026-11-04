"""The till's requests panel: what it sold from the company's shelf, and how it
ended. A cashier's own; every request for the reporting roles."""

from __future__ import annotations

from rest_framework import serializers
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission

from . import card_requests

USE = ("integrations.use_integrations",)


class CardRequestsView(APIView):
    """``GET``: the latest requests. Reads the shop's own records, never the relay."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request):
        return Response({"results": card_requests.recent(request.user)})


class _SettleSerializer(serializers.Serializer):
    lines = serializers.ListField(child=serializers.IntegerField(min_value=1), max_length=50)


class CardRequestsSettleView(APIView):
    """``POST {lines}``: read the open ones back and answer all of them.

    A POST because it may write what the relay said, but safe to repeat: a
    settled line is left alone, and a line is read at most every few seconds.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": USE}

    def post(self, request):
        body = _SettleSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        return Response({"results": card_requests.settle(request.user, body.validated_data["lines"])})
