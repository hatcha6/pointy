"""The till's endpoints for «الشحن المباشر» and «دفع الفواتير».

Thin on purpose: the directory, the country screens, the flags and the recent
recipients are read from the shop's own mirror (:mod:`.services_menu`), and the
two live questions — which network is this number, what exactly does this cost —
are answered by :mod:`.services_quote`. All of them are till work
(``integrations.use_integrations``); the shop's cost of a service goes only to the
reporting roles, as everywhere else on the till.

Refusals are answers, not errors: ``200`` with ``available: false`` and an
``error_code`` when the shop cannot sell (switched off, not linked, the relay
sells none), ``200`` with ``ok: false`` or ``detected: false`` and a stable code
for a number or an amount that cannot be had. A request that is not even shaped
like one is the ordinary ``400``.
"""

from __future__ import annotations

import re

from django.http import HttpResponse
from rest_framework import serializers, status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility

from . import services_logos, services_menu, services_options, services_quote

USE = ("integrations.use_integrations",)
_DIGEST = re.compile(r"[0-9a-f]{64}")
#: The most flags one call may ask for.
MAX_FLAG_CODES = 40


class ServiceQuoteRequestSerializer(serializers.Serializer):
    """What the till asks to have priced: one top-up or one bill payment."""

    # The fields of the other kind are tolerated as null: a client that sends one
    # shape for both has not made a mistake.
    kind = serializers.ChoiceField(choices=services_options.KINDS)
    country = serializers.CharField(max_length=8)
    operator_id = serializers.IntegerField(min_value=1, required=False, allow_null=True)
    biller_id = serializers.IntegerField(min_value=1, required=False, allow_null=True)
    phone = serializers.CharField(max_length=40, required=False, allow_blank=True, allow_null=True)
    account = serializers.CharField(
        max_length=80, required=False, allow_blank=True, allow_null=True
    )
    invoice_id = serializers.CharField(
        max_length=40, required=False, allow_blank=True, allow_null=True
    )
    amount = serializers.CharField(max_length=40)
    amount_currency = serializers.CharField(max_length=8)
    amount_id = serializers.IntegerField(min_value=1, required=False, allow_null=True)

    def validate(self, attrs):
        needed = "operator_id" if attrs["kind"] == services_options.KIND_AIRTIME else "biller_id"
        if attrs.get(needed) is None:
            raise serializers.ValidationError({needed: "This field is required."})
        return attrs


class ServiceDetectRequestSerializer(serializers.Serializer):
    """Which number, in which country. In the body of the request, never its address."""

    country = serializers.CharField(max_length=8)
    phone = serializers.CharField(max_length=40, allow_blank=True)


class ServicesDirectoryView(APIView):
    """Every country the services reach, with its counts — no operators, no flags."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request):
        return Response(services_menu.directory_payload())


class ServicesCountryView(APIView):
    """One country's networks and billers, priced for the till."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request, code: str):
        payload = services_menu.country_payload(
            code, with_cost=user_has_full_visibility(request.user)
        )
        if payload is None:
            return Response({"detail": "unknown country"}, status=status.HTTP_404_NOT_FOUND)
        return Response(services_menu.absolute_logos(payload, request))


class ServicesLogoView(APIView):
    """An operator's logo by its hash: a picture, no secret, so no login.

    A till's image cache fetches it without the session's headers. The address
    is the hash of the picture, which the relay vouched for, and nothing here
    names a supplier.
    """

    authentication_classes: list = []
    permission_classes: list = []

    def get(self, request, digest: str):
        picture = services_logos.picture_for(digest) if _DIGEST.fullmatch(digest) else None
        if picture is None:
            return HttpResponse(status=404)
        response = HttpResponse(picture, content_type="image/png")
        response["Cache-Control"] = "public, max-age=31536000, immutable"
        return response


class ServicesFlagsView(APIView):
    """The flags of some countries, base64 PNGs: ``?codes=ML,NE``."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request):
        codes = list(
            dict.fromkeys(
                code.strip().upper()
                for code in (request.query_params.get("codes") or "").split(",")
                if code.strip()
            )
        )
        if len(codes) > MAX_FLAG_CODES:
            return Response(
                {"detail": f"at most {MAX_FLAG_CODES} codes"}, status=status.HTTP_400_BAD_REQUEST
            )
        return Response(services_menu.flags_payload(codes))


class ServicesDetectView(APIView):
    """The network the relay detects for a phone number, asked live.

    A POST although it changes nothing: a customer's number must not travel in a
    URL, where the access logs of the shop, its proxy and the relay would keep it.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": USE}

    def post(self, request):
        body = ServiceDetectRequestSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        return Response(
            services_menu.absolute_logos(
                services_quote.detect(
                    body.validated_data["country"],
                    body.validated_data["phone"],
                    with_cost=user_has_full_visibility(request.user),
                ),
                request,
            )
        )


class ServicesQuoteView(APIView):
    """The exact price of one thing, sealed for checkout. Spends nothing."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": USE}

    def post(self, request):
        serializer = ServiceQuoteRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return Response(
            services_quote.quote(
                serializer.validated_data, with_cost=user_has_full_visibility(request.user)
            )
        )


class ServicesRecentView(APIView):
    """The numbers topped up lately, newest first, one line each: ``?kind=airtime``."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": USE}

    def get(self, request):
        kind = (request.query_params.get("kind") or services_options.KIND_AIRTIME).strip()
        return Response(services_menu.recent_payload(kind))
