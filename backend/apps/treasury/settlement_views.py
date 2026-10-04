"""Endpoints for held card takings and the processor's settlements."""

from decimal import Decimal, InvalidOperation

from django.utils.dateparse import parse_date
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import NotFound, ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.idempotency import run_idempotent_request
from apps.core.permissions import HasPointyPermission
from apps.core.timeutils import business_local_date

from . import held_days
from .models import CardSettlement, MoneyAccount
from .serializers import MoneyAccountSerializer
from .settlement_match import suggest
from .settlement_serializers import (
    CardSettlementSerializer,
    RecordCardSettlementSerializer,
    held_day_payload,
    held_payment_payload,
    suggestion_payload,
)
from .settlements import cancel_settlement, settlement_payments

MONEY_PLACES = Decimal("0.01")


class CardSettlementViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = CardSettlementSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("treasury.view_cardsettlement",),
        "retrieve": ("treasury.view_cardsettlement",),
        "payments": ("treasury.view_cardsettlement",),
        "create": ("treasury.add_cardsettlement",),
        "cancel": ("treasury.cancel_cardsettlement",),
    }
    queryset = CardSettlement.objects.select_related(
        "clearing_account", "bank_account", "created_by", "cancelled_by"
    )
    filterset_fields = {
        "clearing_account": ["exact"],
        "bank_account": ["exact"],
        "doc_status": ["exact"],
        "settled_on": ["exact", "gte", "lte"],
    }
    ordering_fields = ("settled_on", "created_at", "amount_received")

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(request, lambda: self._create(request))

    def _create(self, request):
        serializer = RecordCardSettlementSerializer(
            data=request.data, context=self.get_serializer_context()
        )
        serializer.is_valid(raise_exception=True)
        settlement = serializer.save()
        return Response(
            CardSettlementSerializer(settlement).data, status=status.HTTP_201_CREATED
        )

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._cancel(request))

    def _cancel(self, request):
        settlement = self.get_object()
        cancel_settlement(
            settlement,
            reason=str(request.data.get("reason", "")).strip(),
            request=request,
        )
        settlement.refresh_from_db()
        return Response(self.get_serializer(settlement).data, status=status.HTTP_200_OK)

    @action(detail=True, methods=["get"])
    def payments(self, request, pk=None):
        """The card sales this settlement paid for."""
        settlement = self.get_object()
        rows = [
            {
                "id": payment.pk,
                "order_id": payment.order_id,
                "invoice_number": getattr(payment.order, "invoice_number", "") or "",
                "paid_at": payment.paid_at.isoformat(),
                "amount": str(payment.amount),
                "commission": str(payment.commission_amount),
                "net": str(
                    (payment.amount - payment.commission_amount).quantize(MONEY_PLACES)
                ),
            }
            for payment in settlement_payments(settlement)
        ]
        return Response({"settlement": settlement.pk, "payments": rows})


def _clearing_account(pk):
    try:
        return MoneyAccount.objects.select_related("settles_into").get(
            pk=pk, kind=MoneyAccount.Kind.CLEARING
        )
    except MoneyAccount.DoesNotExist as exc:
        raise NotFound("حساب قيد التسوية غير موجود.") from exc


def _parse_day(value, default=None):
    if not value:
        return default
    parsed = parse_date(str(value))
    if parsed is None:
        raise ValidationError("صيغة التاريخ غير صحيحة.")
    return parsed


def _parse_amount(value):
    if value in (None, ""):
        return None
    try:
        return Decimal(str(value)).quantize(MONEY_PLACES)
    except (InvalidOperation, ValueError) as exc:
        raise ValidationError("صيغة المبلغ غير صحيحة.") from exc


class ClearingHeldView(APIView):
    """The held processor days of one clearing account, and a proposed match.

    ``?amount=`` (the deposit in the SMS) and ``?settled_on=`` (the day it
    landed, today by default) ask which held days that deposit most likely
    paid; without an amount, the days that should have landed by then.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": ("treasury.view_cardsettlement",)}

    def get(self, request, pk):
        account = _clearing_account(pk)
        today = business_local_date()
        settled_on = _parse_day(request.query_params.get("settled_on"), today)
        amount = _parse_amount(request.query_params.get("amount"))

        days = held_days.pending_days(account)
        suggestion = suggest(days, amount=amount, settled_on=settled_on)
        overdue = [day for day in days if day.expected_on < today]
        zero = Decimal("0.00")
        return Response(
            {
                "account": MoneyAccountSerializer(account).data,
                "today": today.isoformat(),
                "settled_on": settled_on.isoformat(),
                "days": [held_day_payload(day, today=today) for day in days],
                "totals": {
                    "gross": str(sum((day.gross for day in days), zero)),
                    "commission": str(sum((day.commission for day in days), zero)),
                    "net": str(sum((day.net for day in days), zero)),
                    "count": sum(day.count for day in days),
                    "overdue_net": str(sum((day.net for day in overdue), zero)),
                },
                "suggestion": suggestion_payload(suggestion),
            }
        )


class ClearingHeldDayView(APIView):
    """The held card sales of one processor day."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": ("treasury.view_cardsettlement",)}

    def get(self, request, pk, day):
        account = _clearing_account(pk)
        processor_day = _parse_day(day)
        result = held_days.day_payments(account, processor_day)
        return Response(
            {
                "day": processor_day.isoformat(),
                "truncated": result["truncated"],
                "payments": [held_payment_payload(row) for row in result["payments"]],
            }
        )


__all__ = ["CardSettlementViewSet", "ClearingHeldDayView", "ClearingHeldView"]
