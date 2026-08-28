from datetime import timedelta

from django.utils.dateparse import parse_date
from rest_framework import mixins, viewsets
from rest_framework.exceptions import NotFound, ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.idempotency import run_idempotent_request
from apps.core.permissions import HasPointyPermission
from apps.core.timeutils import business_local_date

from .models import MoneyAccount, MoneyCount, MoneyTransfer
from .movements import account_movements
from .position import treasury_position
from .serializers import (
    MoneyAccountSerializer,
    MoneyCountSerializer,
    MoneyTransferSerializer,
    TreasuryPositionSerializer,
)

# A month by default: long enough to cover the gap between two cash counts,
# short enough that the row ceiling is rarely reached.
DEFAULT_MOVEMENT_DAYS = 30


class MoneyAccountViewSet(viewsets.ModelViewSet):
    serializer_class = MoneyAccountSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("treasury.view_moneyaccount",),
        "retrieve": ("treasury.view_moneyaccount",),
        "create": ("treasury.add_moneyaccount",),
        "update": ("treasury.change_moneyaccount",),
        "partial_update": ("treasury.change_moneyaccount",),
        "destroy": ("treasury.delete_moneyaccount",),
    }
    queryset = MoneyAccount.objects.all()
    filterset_fields = ("kind", "is_active")
    search_fields = ("name", "bank_name", "account_number")
    ordering_fields = ("display_order", "name", "created_at")


class MoneyTransferViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = MoneyTransferSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("treasury.view_moneytransfer",),
        "retrieve": ("treasury.view_moneytransfer",),
        "create": ("treasury.add_moneytransfer",),
    }
    queryset = MoneyTransfer.objects.select_related(
        "from_account", "to_account", "created_by"
    )
    filterset_fields = {
        "from_account": ["exact"],
        "to_account": ["exact"],
        "moved_at": ["exact", "gte", "lte"],
    }
    ordering_fields = ("moved_at", "amount", "created_at")

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(MoneyTransferViewSet, self).create(request, *args, **kwargs),
        )


class MoneyCountViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = MoneyCountSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("treasury.view_moneycount",),
        "retrieve": ("treasury.view_moneycount",),
        "create": ("treasury.add_moneycount",),
    }
    queryset = MoneyCount.objects.select_related("account", "created_by")
    filterset_fields = {
        "account": ["exact"],
        "counted_at": ["gte", "lte"],
    }
    ordering_fields = ("counted_at", "variance")

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(MoneyCountViewSet, self).create(request, *args, **kwargs),
        )


class TreasuryPositionView(APIView):
    """What the shop should be holding right now, account by account."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": ("treasury.view_moneyaccount",)}

    def get(self, request):
        as_of = _parse_date(request.query_params.get("as_of"), business_local_date())
        position = treasury_position(as_of=as_of)
        return Response(TreasuryPositionSerializer(position).data)


class AccountMovementsView(APIView):
    """The individual money events behind one account's balance."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": ("treasury.view_moneyaccount",)}

    def get(self, request, pk):
        try:
            account = MoneyAccount.objects.get(pk=pk)
        except MoneyAccount.DoesNotExist as exc:
            raise NotFound("الحساب غير موجود.") from exc

        today = business_local_date()
        end = _parse_date(request.query_params.get("end"), today)
        start = _parse_date(
            request.query_params.get("start"),
            end - timedelta(days=DEFAULT_MOVEMENT_DAYS),
        )
        if start > end:
            raise ValidationError("تاريخ البداية بعد تاريخ النهاية.")

        result = account_movements(account, start=start, end=end)
        return Response(
            {
                "account": MoneyAccountSerializer(account).data,
                "start": start.isoformat(),
                "end": end.isoformat(),
                "truncated": result["truncated"],
                "rows": [
                    {
                        "source": row["source"],
                        "date": row["date"].isoformat(),
                        "amount": str(row["amount"]),
                        "direction": row["direction"],
                        "description": row["description"],
                        "reference": row["reference"],
                        "related_id": row["related_id"],
                    }
                    for row in result["rows"]
                ],
            }
        )


def _parse_date(value, default):
    if not value:
        return default
    parsed = parse_date(value)
    if parsed is None:
        raise ValidationError("صيغة التاريخ غير صحيحة.")
    return parsed
