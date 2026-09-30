"""The wallet endpoints the app calls.

All of them need ``core.change_shopsettings``, like the subscription page the
wallet lives on: seeing the company balance and spending the shop's money on it
are the owner's and the manager's business, not the till's.
"""

from decimal import Decimal

from rest_framework import serializers, status, views
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.services import record_domain_event
from apps.core.permissions import HasPointyPermission
from apps.expenses.models import ExpenseCategory

from . import services

IDEMPOTENCY_HEADER = "Idempotency-Key"


class TopUpRequestSerializer(serializers.Serializer):
    amount = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=Decimal("0.01")
    )
    method = serializers.CharField(
        required=False, default=services.TOPUP_METHOD_LOCAL_BANK_CARDS, max_length=40
    )
    # The app's own key for this attempt: a retried POST (a dropped response,
    # a double tap) gets the SAME checkout back instead of a second one.
    idempotency_key = serializers.RegexField(
        r"^[A-Za-z0-9:_./=-]{1,100}$", required=False, allow_blank=True
    )
    record_as_expense = serializers.BooleanField(required=False, allow_null=True, default=None)


class WalletSettingsSerializer(serializers.Serializer):
    record_topups_as_expenses = serializers.BooleanField(required=False)
    expense_category = serializers.PrimaryKeyRelatedField(
        queryset=ExpenseCategory.objects.all(), required=False, allow_null=True
    )


class WalletAPIView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("core.change_shopsettings",)

    @staticmethod
    def error_response(error):
        return Response(error.payload(), status=error.status)

    @staticmethod
    def page_params(request):
        try:
            limit = int(request.query_params.get("limit") or services.PAGE_LIMIT)
        except ValueError:
            limit = services.PAGE_LIMIT
        return {
            "before": str(request.query_params.get("before") or "")[:64],
            "limit": min(max(limit, 1), 100),
        }


class WalletView(WalletAPIView):
    def get(self, request):
        return Response(services.wallet_overview())


class WalletSettingsView(WalletAPIView):
    def get(self, request):
        return Response(services.wallet_settings_payload())

    def patch(self, request):
        serializer = WalletSettingsSerializer(data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        settings = services.update_wallet_settings(
            record_topups_as_expenses=data.get("record_topups_as_expenses"),
            expense_category=data.get("expense_category", ...),
        )
        return Response(services.wallet_settings_payload(settings))


class WalletTopUpListView(WalletAPIView):
    def get(self, request):
        try:
            return Response(services.list_topups(**self.page_params(request)))
        except services.WalletError as error:
            return self.error_response(error)

    def post(self, request):
        serializer = TopUpRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        key = data.get("idempotency_key") or request.headers.get(IDEMPOTENCY_HEADER, "")
        try:
            result = services.start_topup(
                user=request.user,
                amount=data["amount"],
                method=data["method"],
                idempotency_key=str(key)[:100],
                record_as_expense=data.get("record_as_expense"),
            )
        except services.WalletError as error:
            return self.error_response(error)
        if not result["replayed"]:
            record_domain_event(
                name="wallet.topup.started",
                user=request.user,
                entity_type="wallet_topup",
                attributes={
                    "invoice_no": result["top_up"]["invoice_no"],
                    "method": result["top_up"]["method"],
                    "test_mode": result["top_up"]["test_mode"],
                },
                metrics={"amount": float(data["amount"])},
            )
        return Response(
            result,
            status=status.HTTP_200_OK if result["replayed"] else status.HTTP_201_CREATED,
        )


class WalletTopUpDetailView(WalletAPIView):
    def get(self, request, relay_id):
        try:
            return Response({"top_up": services.refresh_topup(relay_id)})
        except services.WalletError as error:
            return self.error_response(error)


class WalletEntriesView(WalletAPIView):
    def get(self, request):
        kind = str(request.query_params.get("kind") or "")[:16]
        try:
            return Response(services.list_entries(kind=kind, **self.page_params(request)))
        except services.WalletError as error:
            return self.error_response(error)
