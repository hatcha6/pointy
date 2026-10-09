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
    # Two places: the gateway takes the dirham's three, but the expense a paid
    # top-up becomes keeps two, and it must book exactly what was paid. The
    # relay holds the real bounds and answers with them.
    amount = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=Decimal("0.01")
    )
    method = serializers.CharField(
        required=False, default=services.TOPUP_METHOD_BANK_CARDS, max_length=40
    )
    # The app's own key for this attempt: a retried POST (a dropped response,
    # a double tap) gets the SAME payment back instead of a second one.
    idempotency_key = serializers.RegexField(
        r"^[A-Za-z0-9:_./=-]{1,100}$", required=False, allow_blank=True
    )
    record_as_expense = serializers.BooleanField(required=False, allow_null=True, default=None)
    # The payer's phone or wallet card number, and Sadad's birth year: passed
    # to the relay, which checks them per method, and never stored here.
    user_identifier = serializers.CharField(
        required=False, allow_blank=True, default="", max_length=40, trim_whitespace=True
    )
    birth_year = serializers.CharField(
        required=False, allow_blank=True, default="", max_length=8, trim_whitespace=True
    )


class BankTransferRequestSerializer(serializers.Serializer):
    """A transfer the shop made to the company's account. The receipt is the
    uploaded ``receipt``, or what the paired phone sent (``receipt_attachment_id``)."""

    amount = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=Decimal("0.01")
    )
    channel = serializers.ChoiceField(choices=("lypay", "onepay"))
    payer_bank = serializers.RegexField(r"^[a-z0-9_-]{1,32}$")
    payer_account = serializers.CharField(max_length=40, trim_whitespace=True)
    payer_iban = serializers.CharField(max_length=40, trim_whitespace=True)
    to_account = serializers.CharField(required=False, allow_blank=True, default="", max_length=40)
    idempotency_key = serializers.RegexField(
        r"^[A-Za-z0-9:_./=-]{1,100}$", required=False, allow_blank=True
    )
    record_as_expense = serializers.BooleanField(required=False, allow_null=True, default=None)
    receipt = serializers.FileField(required=False, allow_empty_file=False)
    receipt_attachment_id = serializers.IntegerField(required=False, allow_null=True, default=None)

    def validate(self, attrs):
        if attrs.get("receipt") is None and not attrs.get("receipt_attachment_id"):
            raise serializers.ValidationError({"receipt": "أرفق إيصال التحويل."})
        return attrs


class SmsAllocationSerializer(serializers.Serializer):
    # The dirham's three places: nothing is booked, and a message costs 0.150.
    # The relay holds the real floor (one message) and answers with it.
    amount = serializers.DecimalField(
        max_digits=12, decimal_places=3, min_value=Decimal("0.001")
    )
    idempotency_key = serializers.RegexField(
        r"^[A-Za-z0-9:_./=-]{1,100}$", required=False, allow_blank=True
    )


class VoucherAllocationSerializer(serializers.Serializer):
    # Two places, not the dirham's three: the move is booked into the
    # «كروت دفتر» float, which keeps two, and every card it pays for is priced
    # in two. The relay holds the real bounds and answers with them.
    amount = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=Decimal("0.01")
    )
    idempotency_key = serializers.RegexField(
        r"^[A-Za-z0-9:_./=-]{1,100}$", required=False, allow_blank=True
    )


class PlanPurchaseSerializer(serializers.Serializer):
    plan = serializers.ChoiceField(choices=("remote_access", "ai"))
    periods = serializers.IntegerField(min_value=1, max_value=12, default=1)
    idempotency_key = serializers.RegexField(
        r"^[A-Za-z0-9:_./=-]{1,100}$", required=False, allow_blank=True
    )


class TopUpConfirmSerializer(serializers.Serializer):
    # Digits as the payer typed them; the relay reads Arabic-Indic digits too.
    otp = serializers.CharField(max_length=16, trim_whitespace=True)


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
                user_identifier=data["user_identifier"],
                birth_year=data["birth_year"],
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


class WalletBankTransferView(WalletAPIView):
    """POST a bank transfer with its receipt (multipart)."""

    def post(self, request):
        serializer = BankTransferRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        key = data.get("idempotency_key") or request.headers.get(IDEMPOTENCY_HEADER, "")
        try:
            result = services.start_bank_transfer(
                user=request.user,
                amount=data["amount"],
                channel=data["channel"],
                payer_bank=data["payer_bank"],
                payer_account=data["payer_account"],
                payer_iban=data["payer_iban"],
                to_account=data["to_account"],
                receipt_file=data.get("receipt"),
                receipt_attachment_id=data.get("receipt_attachment_id"),
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


class WalletTopUpConfirmView(WalletAPIView):
    """The code the payer's provider texted them."""

    def post(self, request, relay_id):
        serializer = TopUpConfirmSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            result = services.confirm_topup(relay_id, serializer.validated_data["otp"])
        except services.WalletError as error:
            return self.error_response(error)
        top_up = result["top_up"]
        if top_up.get("status") == "paid":
            record_domain_event(
                name="wallet.topup.paid",
                user=request.user,
                entity_type="wallet_topup",
                attributes={
                    "invoice_no": top_up.get("invoice_no", ""),
                    "method": top_up.get("method", ""),
                    "test_mode": top_up.get("test_mode", False),
                },
            )
        # 202: the gateway took the code without a verdict yet; the app polls.
        accepted = result["code"] == "awaiting_gateway"
        return Response(
            result, status=status.HTTP_202_ACCEPTED if accepted else status.HTTP_200_OK
        )


class WalletTopUpCancelView(WalletAPIView):
    """The owner backing out before sending the code."""

    def post(self, request, relay_id):
        try:
            return Response(services.cancel_topup(relay_id))
        except services.WalletError as error:
            return self.error_response(error)


class WalletEntriesView(WalletAPIView):
    def get(self, request):
        kind = str(request.query_params.get("kind") or "")[:16]
        account = str(request.query_params.get("account") or "")[:16]
        try:
            return Response(
                services.list_entries(kind=kind, account=account, **self.page_params(request))
            )
        except services.WalletError as error:
            return self.error_response(error)


class WalletSmsAllocationView(WalletAPIView):
    """Moving money from the main wallet into the SMS balance."""

    def post(self, request):
        serializer = SmsAllocationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        key = data.get("idempotency_key") or request.headers.get(IDEMPOTENCY_HEADER, "")
        try:
            result = services.allocate_to_sms(
                user=request.user, amount=data["amount"], idempotency_key=str(key)[:100]
            )
        except services.WalletError as error:
            return self.error_response(error)
        if not result["replayed"]:
            record_domain_event(
                name="wallet.sms.allocated",
                user=request.user,
                entity_type="wallet_transfer",
                metrics={"amount": float(data["amount"])},
            )
        return Response(
            result,
            status=status.HTTP_200_OK if result["replayed"] else status.HTTP_201_CREATED,
        )


class WalletVoucherAllocationView(WalletAPIView):
    """Moving money from the main wallet into the voucher balance («كروت دفتر»)."""

    def post(self, request):
        serializer = VoucherAllocationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        key = data.get("idempotency_key") or request.headers.get(IDEMPOTENCY_HEADER, "")
        try:
            result = services.allocate_to_vouchers(
                user=request.user, amount=data["amount"], idempotency_key=str(key)[:100]
            )
        except services.WalletError as error:
            return self.error_response(error)
        if not result["replayed"]:
            record_domain_event(
                name="wallet.vouchers.allocated",
                user=request.user,
                entity_type="wallet_transfer",
                metrics={"amount": float(data["amount"])},
            )
        return Response(
            result,
            status=status.HTTP_200_OK if result["replayed"] else status.HTTP_201_CREATED,
        )


class WalletPlanPurchaseView(WalletAPIView):
    """Paying for remote access or the assistant from the main wallet."""

    def post(self, request):
        serializer = PlanPurchaseSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        key = data.get("idempotency_key") or request.headers.get(IDEMPOTENCY_HEADER, "")
        try:
            result = services.purchase_plan(
                user=request.user,
                plan=data["plan"],
                periods=data["periods"],
                idempotency_key=str(key)[:100],
            )
        except services.WalletError as error:
            return self.error_response(error)
        if not result["replayed"]:
            record_domain_event(
                name="wallet.plan.purchased",
                user=request.user,
                entity_type="wallet_plan",
                attributes={"plan": data["plan"]},
                metrics={"periods": data["periods"]},
            )
        return Response(
            result,
            status=status.HTTP_200_OK if result["replayed"] else status.HTTP_201_CREATED,
        )
