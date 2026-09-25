from django.db import transaction
from decimal import Decimal
from rest_framework import serializers

from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.sales.documents import settled_amount
from apps.sales.models import Order
from apps.sales.serializers import CheckoutPaymentSerializer
from apps.treasury.models import MoneyAccount
from . import terminals
from .card_receipts import (
    CardReceiptError,
    amount_matches,
    parse_receipt_url,
    terminal_is_trusted,
)
from .models import Payment

_MISSING = object()


def validate_bank_money_account(account, method, *, field="money_account"):
    """Refuse an account that cannot possibly have received this money.

    Both rules exist because the alternative is a figure nobody can explain: a
    cash sale filed against a bank account makes a bank balance that no
    statement will ever agree with, and a payment into the cash box would be
    counted twice — once here and once in the drawer.
    """
    if account is None:
        return None
    # The one statement of which methods move money through a bank, borrowed
    # from the module that has to agree with it — the money position routes on
    # exactly this list, and a second copy here would eventually disagree.
    from apps.treasury.position import BANK_METHODS

    if account.kind != MoneyAccount.Kind.BANK:
        raise serializers.ValidationError(
            {field: "Only a bank account can be named on a payment."}
        )
    if not account.is_active:
        raise serializers.ValidationError({field: "Account is not active."})
    if method not in BANK_METHODS:
        raise serializers.ValidationError(
            {field: "Only a card or transfer payment lands in a bank account."}
        )
    return account


def payment_commission_values(method, amount):
    settings = ShopSettings.load()
    percent = Decimal(settings.payment_commission_percent(method))
    commission = (Decimal(amount) * percent / Decimal("100")).quantize(
        Decimal("0.01")
    )
    return percent, commission


class PaymentSerializer(serializers.ModelSerializer):
    card_receipt_url = serializers.CharField(
        write_only=True,
        required=False,
        allow_blank=True,
        trim_whitespace=True,
    )
    # Which bank account took this money. Omitted by every till that has not
    # been told about the shop's accounts, and by every shop that has only one
    # — and then resolved from the terminal that printed the slip, or left null
    # so the money position routes it the way it always did.
    money_account = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.all(),
        required=False,
        allow_null=True,
    )

    class Meta:
        model = Payment
        fields = [
            "id",
            "order",
            "method",
            "amount",
            "commission_percent",
            "commission_amount",
            "external_reference",
            "card_receipt_data",
            "card_receipt_url",
            "money_account",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "commission_percent",
            "commission_amount",
            "card_receipt_data",
            "created_at",
            "updated_at",
        )

    def validate_method(self, method):
        if not ShopSettings.load().payment_method_enabled(method):
            raise serializers.ValidationError("Payment method is disabled.")
        return method

    def validate_amount(self, amount):
        # Money only comes IN here. It goes back by cancelling a payment
        # (``services.cancel_payment``) or through a return or void
        # (``create_order_adjustment``), both server-side and both leaving a
        # trail. A negative row posted here left none: the invoice owed again
        # and the cash box dropped with nothing to say why. Zero settles nothing.
        #
        # New payments only. An update re-reads the stored amount, which a
        # refund row carries negative by design, and the money fields of an
        # existing payment are frozen at the model layer anyway.
        if self.instance is None and amount <= 0:
            raise serializers.ValidationError(
                "Amount must be positive. Money goes back by cancelling a "
                "payment or through a return."
            )
        return amount

    def validate_order(self, order):
        request = self.context.get("request")
        # Account-level AR collection is intentionally cross-owner — a cashier may
        # settle a debt another user issued — so it opts out of the per-session
        # owner gate (the action's permission already authorized the collection).
        if self.context.get("allow_cross_owner"):
            return order
        if request is None or user_is_manager(request.user):
            return order

        owner_key = f"user:{request.user.pk}"
        if order.register_session is None or order.register_session.owner_key != owner_key:
            raise serializers.ValidationError("Order is not available for this user.")
        return order

    def validate(self, attrs):
        attrs = super().validate(attrs)
        order = attrs.get("order", getattr(self.instance, "order", None))
        amount = attrs.get("amount", getattr(self.instance, "amount", None))
        method = attrs.get("method", getattr(self.instance, "method", None))
        receipt_url = attrs.pop("card_receipt_url", "").strip()
        settings = ShopSettings.load()
        if receipt_url and method != Payment.Method.CARD:
            raise serializers.ValidationError(
                {"card_receipt_url": "Card receipt validation is only for card payments."}
            )
        if method == Payment.Method.CARD:
            existing_receipt_data = getattr(self.instance, "card_receipt_data", {}) or {}
            if receipt_url:
                try:
                    receipt = parse_receipt_url(receipt_url)
                except CardReceiptError as exc:
                    raise serializers.ValidationError(
                        {"card_receipt_url": str(exc)}
                    ) from exc
                # A receipt whose provider keeps the details on its own server
                # cannot be matched here: the link carries an opaque token and
                # nothing else, and the fetch that resolves it takes tens of
                # seconds. Blocking a checkout on that would hang the till, so
                # the slip is recorded as captured-but-unproven and a background
                # task settles it. Everything below is the check we CAN do now.
                if receipt.is_verified:
                    # An account collection validates ONE receipt against the
                    # TOTAL, then splits it across invoices — so a sub-payment's
                    # amount won't match the receipt. That path sets
                    # ``card_receipt_amount_validated`` after checking the total
                    # once.
                    if not self.context.get(
                        "card_receipt_amount_validated"
                    ) and not amount_matches(amount, receipt):
                        raise serializers.ValidationError(
                            {
                                "card_receipt_url": (
                                    "Card receipt amount does not match the payment amount."
                                )
                            }
                        )
                    if not terminal_is_trusted(
                        receipt, settings.trusted_card_terminal_ids
                    ):
                        raise serializers.ValidationError(
                            {
                                "card_receipt_url": (
                                    "Card receipt terminal is not trusted for this shop."
                                )
                            }
                        )
                receipt_data = receipt.to_payment_data()
                expected_amount = self.context.get("card_receipt_expected_amount")
                if expected_amount is not None and not receipt.is_verified:
                    # One slip covering several invoices: remember the total it
                    # should prove, or each split row would be checked against
                    # its own share and every one would fail.
                    receipt_data["expected_amount"] = f"{Decimal(expected_amount):.2f}"
                attrs["card_receipt_data"] = receipt_data
                # Only a proved receipt carries a reference worth recording. An
                # unproved one would contribute its own opaque token, which is
                # not a payment reference and would then sit in the field
                # blocking the real RRN once the issuer supplies it.
                if receipt.is_verified and not attrs.get("external_reference"):
                    attrs["external_reference"] = receipt.reference[:128]
            elif settings.require_card_payment_receipt and not existing_receipt_data:
                raise serializers.ValidationError(
                    {"card_receipt_url": "Card receipt validation is required."}
                )
        if "money_account" in attrs:
            validate_bank_money_account(attrs["money_account"], method)
        # Only an update reaches here with a non-positive amount: a refund or
        # cancellation row's, re-read from the instance. ``validate_amount``
        # refuses a new one.
        if order is None or amount is None or amount <= 0:
            return attrs

        if self._settled(order) + amount > order.total:
            raise serializers.ValidationError(
                {"amount": "Payment total cannot exceed the order total."}
            )
        return attrs

    def _settled(self, order):
        """What the order was settled by before this payment.

        ``settled_amount``: its payments plus what returns refunded. A refund
        is a negative payment, so payments alone would let a part-returned sale
        be paid for twice, and would keep one that is square from turning paid.
        Two rows are left out: this payment's own, when it is being edited, and
        one it is taken to replace (``services.replace_payment``). That one is
        given back straight afterwards and until then would count twice.
        """
        payments = order.payments.all()
        for other in (self.instance, self.context.get("replacing")):
            if other is not None:
                payments = payments.exclude(pk=other.pk)
        return settled_amount(
            order,
            paid=sum(payments.values_list("amount", flat=True), Decimal("0.00")),
        )

    @transaction.atomic
    def create(self, validated_data):
        order = Order.objects.select_for_update().get(pk=validated_data["order"].pk)
        validated_data["order"] = order
        amount = validated_data["amount"]
        settled = self._settled(order)
        if settled + amount > order.total:
            raise serializers.ValidationError(
                {"amount": "Payment total cannot exceed the order total."}
            )

        # A slip that names its terminal names its bank: the shop said once,
        # in settings, which account each machine settles into, and the cashier
        # never has to say it again. Only ever fills a blank — a cashier who
        # picked an account has overruled the mapping on purpose, and a wrongly
        # mapped terminal must not be able to silently move their money.
        if not validated_data.get("money_account"):
            resolved = terminals.account_for_receipt(
                validated_data.get("card_receipt_data")
            )
            if resolved is not None and resolved.is_active:
                validated_data["money_account"] = resolved

        percent, commission = payment_commission_values(
            validated_data["method"],
            amount,
        )
        validated_data["commission_percent"] = percent
        validated_data["commission_amount"] = commission
        # Attribute the payment to the COLLECTING session for drawer
        # reconciliation. Defaults to the order's session (checkout), but a later
        # payment against a debt invoice passes the current session via context.
        register_session = self.context.get("register_session", _MISSING)
        validated_data["register_session"] = (
            order.register_session if register_session is _MISSING else register_session
        )
        created_by = self.context.get("created_by", _MISSING)
        if created_by is not _MISSING:
            validated_data["created_by"] = created_by
        else:
            request = self.context.get("request")
            user = getattr(request, "user", None)
            if user is not None and getattr(user, "is_authenticated", False):
                validated_data["created_by"] = user
        paid_at = self.context.get("paid_at", _MISSING)
        if paid_at is not _MISSING:
            validated_data["paid_at"] = paid_at
        payment = super().create(validated_data)
        if payment.method == Payment.Method.CARD and payment.card_receipt_data:
            # Promote the scanned receipt into a deduped PaymentCard and link it
            # to a customer (minting a placeholder if the order has none yet).
            # A receipt still awaiting its issuer has no card details yet, so
            # this is a no-op for one; the verification task links it once the
            # fetch fills them in.
            from apps.customers.services import link_card_payment

            link_card_payment(payment)
            from .verification import schedule_receipt_verification

            schedule_receipt_verification(payment)
        if order.status != Order.Status.PAID:
            settled = (settled + amount).quantize(Decimal("0.01"))
            if settled >= order.total:
                from apps.sales.services import mark_order_paid

                mark_order_paid(
                    order,
                    request=self.context.get("request"),
                    stock_already_recorded=self.context.get(
                        "stock_already_recorded",
                        False,
                    ),
                )
        return payment


class PaymentLedgerSerializer(serializers.ModelSerializer):
    """Read-only projection of a customer payment for the Payments hub.

    Kept separate from ``PaymentSerializer`` so the checkout write contract is
    untouched. Exposes the linked order's receipt number and customer so the
    money-in ledger can render a row without an extra round-trip.
    """

    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    order_receipt_number = serializers.CharField(
        source="order.receipt_number",
        read_only=True,
    )
    # ``account_entry`` when the payment collected a debt written onto the
    # customer's account (an opening balance, an adjustment) rather than an
    # invoice — the hub names it by its entry, not as a sale.
    order_sale_type = serializers.CharField(
        source="order.sale_type",
        read_only=True,
    )
    customer = serializers.PrimaryKeyRelatedField(
        source="order.customer",
        read_only=True,
    )
    customer_name = serializers.SerializerMethodField()

    class Meta:
        model = Payment
        fields = [
            "id",
            "method",
            "amount",
            "commission_amount",
            "commission_percent",
            "external_reference",
            "paid_at",
            "created_at",
            "created_by",
            "created_by_username",
            "order",
            "order_receipt_number",
            "order_sale_type",
            "customer",
            "customer_name",
        ]
        read_only_fields = fields

    def get_customer_name(self, payment):
        customer = payment.order.customer if payment.order_id else None
        return customer.full_name if customer is not None else None


class PaymentReplacementSerializer(serializers.Serializer):
    """What a payment is taken through instead (``services.replace_payment``).

    Each tender has the shape a till sends at checkout, so a replacement card
    carries its receipt and its bank account exactly as the original sale's
    would have.
    """

    reason = serializers.CharField(required=False, allow_blank=True, default="")
    payments = CheckoutPaymentSerializer(many=True, allow_empty=False)


class CardTerminalSerializer(serializers.ModelSerializer):
    """A card machine and the bank account it settles into.

    The account is echoed back in enough detail to draw the shop's own bank
    row — name, bank, mark — so the settings screen can show *which bank this
    terminal feeds* without a second request per terminal.
    """

    money_account_name = serializers.CharField(
        source="money_account.name", read_only=True, default=""
    )
    money_account_bank_slug = serializers.CharField(
        source="money_account.bank_slug", read_only=True, default=""
    )
    money_account_bank_name = serializers.CharField(
        source="money_account.bank_name", read_only=True, default=""
    )

    class Meta:
        from .models import CardTerminal as _CardTerminal

        model = _CardTerminal
        fields = (
            "id",
            "terminal_id",
            "label",
            "money_account",
            "money_account_name",
            "money_account_bank_slug",
            "money_account_bank_name",
            "is_active",
            "display_order",
        )

    def validate_terminal_id(self, value):
        terminal_id = terminals.normalize(value)
        if not terminal_id:
            raise serializers.ValidationError("A terminal id is required.")
        from .models import CardTerminal

        clash = CardTerminal.objects.filter(terminal_id=terminal_id)
        if self.instance is not None:
            clash = clash.exclude(pk=self.instance.pk)
        if clash.exists():
            raise serializers.ValidationError("This terminal is already registered.")
        return terminal_id

    def validate_money_account(self, account):
        if account is None:
            return None
        if account.kind != MoneyAccount.Kind.BANK:
            raise serializers.ValidationError(
                "A terminal settles into a bank account."
            )
        return account

    def create(self, validated_data):
        instance = super().create(validated_data)
        terminals.refresh_settings_mirror()
        return instance

    def update(self, instance, validated_data):
        instance = super().update(instance, validated_data)
        terminals.refresh_settings_mirror()
        return instance
