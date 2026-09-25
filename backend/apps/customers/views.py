import logging
from decimal import Decimal

from django.db import transaction
from django.db.models import Count, Max, Prefetch, Q, Sum
from django.shortcuts import get_object_or_404
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.catalog.models import VariantOptionValue
from apps.core.dispatch import enqueue_or_raise
from apps.core.idempotency import run_idempotent_request
from apps.core.models import ShopSettings
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility
from apps.sales.models import (
    Order,
    OrderAdjustment,
    RegisterSession,
    transactional_sale_q,
)
from apps.sales.serializers import (
    CustomerAccountPaymentSerializer,
    OrderSerializer,
)
from apps.balances.customers import account_position

from .models import Customer, PaymentCard
from .receivables import assess_credit, customer_balance
from .serializers import (
    CustomerOrderAdjustmentSerializer,
    CustomerSerializer,
    PaymentCardSerializer,
)
from .services import merge_customers

logger = logging.getLogger(__name__)


class CustomerEndpointPermission(HasPointyPermission):
    """Per-action permission map, plus setting-gated cashier access.

    When ``allow_cashier_customer_access`` is on, a cashier (anyone with
    ``sales.add_order``) may look up customers and collect a customer's debt,
    but NOT browse a customer's invoices (orders/adjustments) or create/edit
    customer records. Managers/accountants are unaffected — they pass through
    the permission map exactly as before.
    """

    CASHIER_ACTIONS = frozenset(
        {"list", "retrieve", "sales_summary", "record_payment"}
    )

    def has_permission(self, request, view):
        if super().has_permission(request, view):
            return True
        user = request.user
        return bool(
            getattr(view, "action", None) in self.CASHIER_ACTIONS
            and user
            and user.is_authenticated
            and user.has_perm("sales.add_order")
            and ShopSettings.load().allow_cashier_customer_access
        )


class CustomerViewSet(viewsets.ModelViewSet):
    serializer_class = CustomerSerializer
    permission_classes = [IsAuthenticated, CustomerEndpointPermission]
    permission_map = {
        "list": ("customers.view_customer",),
        "retrieve": ("customers.view_customer",),
        "sales_summary": ("customers.view_customer", "sales.view_order"),
        "orders": ("customers.view_customer", "sales.view_order"),
        "adjustments": ("customers.view_customer", "sales.view_order"),
        "create": ("customers.add_customer",),
        "update": ("customers.change_customer",),
        "partial_update": ("customers.change_customer",),
        "destroy": ("customers.delete_customer",),
        "merge": ("customers.change_customer", "customers.delete_customer"),
        "recompute_segments": ("customers.change_customer",),
        # The till's "me": anyone who can ring up a sale may put it on their own
        # staff account. It reads no one else's record, so it needs no customer
        # permission and ignores ``allow_cashier_customer_access``.
        "staff_account": ("sales.add_order",),
        # Map entry = managers/accountants. Cashiers reach record_payment via
        # CustomerEndpointPermission when ``allow_cashier_customer_access`` is on
        # (they have ``sales.add_order`` + their own open session, and the
        # collecting session gets the cash). Allocation spans ALL of the
        # customer's open debt, so a cashier can settle a debt another cashier
        # issued. Accountants have no till/session, so AR collection by them
        # needs a separate back-office flow — this path doesn't serve them.
        "record_payment": ("customers.view_customer", "sales.add_order"),
        # Spend credit the shop owes the customer against what they owe. Moves
        # no money and changes neither figure's net, so it asks for no more
        # than a collection does — a collection does this itself, first.
        "apply_credit": ("customers.view_customer", "sales.add_order"),
    }
    queryset = Customer.objects.all()
    filterset_fields = (
        "is_active",
        "gender",
        "marketing_consent",
        "is_auto_created",
        # Filter the contacts list by RFM rank (?rfm_segment=champion).
        "rfm_segment",
    )
    search_fields = (
        "customer_number",
        "full_name",
        "phone",
        "email",
    )
    ordering_fields = (
        "full_name",
        "created_at",
        "updated_at",
        "birthday",
        "customer_number",
        # Sort "best customers first" by overall RFM score / spend / recency.
        "rfm_score",
        "rfm_monetary",
        "rfm_frequency",
        "rfm_last_purchase_at",
    )

    def get_queryset(self):
        # The Count annotation adds a GROUP BY, which drops the model's default
        # ordering (and trips DRF's pagination warning), so re-apply it explicitly.
        queryset = (
            super()
            .get_queryset()
            .select_related("staff_employee")
            .annotate(card_count=Count("cards"))
            .order_by("full_name", "customer_number")
        )
        # Auto-created placeholder card-customers clutter the contacts list, so
        # hide them by default. The dedicated "unclaimed cards" view opts back in
        # with ?is_auto_created=true; retrieve and other actions still see all.
        if self.action == "list" and "is_auto_created" not in self.request.query_params:
            queryset = queryset.filter(is_auto_created=False)
        return queryset

    @action(detail=True, methods=["post"])
    def merge(self, request, pk=None):
        target = self.get_object()
        source_id = request.data.get("source_id")
        if not source_id:
            raise serializers.ValidationError({"source_id": "This field is required."})
        source = get_object_or_404(Customer, pk=source_id)
        if source.pk == target.pk:
            raise serializers.ValidationError(
                {"source_id": "Cannot merge a customer into itself."}
            )
        source_number = source.customer_number
        merge_customers(source=source, target=target)
        record_domain_event(
            name="customers.customer.merged",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.WARNING,
            user=request.user,
            entity_type="customer",
            entity_id=target.pk,
            attributes={
                "target_customer_number": target.customer_number,
                "source_customer_number": source_number,
            },
        )
        serializer = self.get_serializer(self.get_queryset().get(pk=target.pk))
        return Response(serializer.data)

    def perform_create(self, serializer):
        customer = serializer.save()
        record_domain_event(
            name="customers.customer.created",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=self.request.user,
            entity_type="customer",
            entity_id=customer.pk,
            attributes={
                "customer_number": customer.customer_number,
                "full_name_present": bool(customer.full_name),
                "phone_present": bool(customer.phone),
                "email_present": bool(customer.email),
            },
        )

    def perform_update(self, serializer):
        customer = serializer.save()
        record_domain_event(
            name="customers.customer.updated",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=self.request.user,
            entity_type="customer",
            entity_id=customer.pk,
            attributes={
                "customer_number": customer.customer_number,
                "is_active": customer.is_active,
                "changed_fields": sorted(serializer.validated_data.keys()),
            },
        )

    def perform_destroy(self, instance):
        customer_id = instance.pk
        customer_number = instance.customer_number
        is_active = instance.is_active
        instance.delete()
        record_domain_event(
            name="customers.customer.deleted",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.WARNING,
            user=self.request.user,
            entity_type="customer",
            entity_id=customer_id,
            attributes={
                "customer_number": customer_number,
                "was_active": is_active,
            },
        )

    @action(detail=False, methods=["post"], url_path="recompute-segments")
    def recompute_segments(self, request):
        """Kick off an out-of-band RFM re-segmentation of all customers.

        Ranks otherwise refresh on the nightly schedule; this lets a manager
        force a refresh (e.g. right after a big import) without waiting. The work
        runs on a Celery worker so the request returns immediately.
        """
        from .tasks import recompute_customer_segments_task

        # Bounded, and fail-closed on the answer: this endpoint promises the work
        # was scheduled, so an unreachable broker must say so rather than park
        # the manager on a spinner or report a 202 for a message nobody took.
        try:
            async_result = enqueue_or_raise(recompute_customer_segments_task)
        except Exception:
            logger.warning("could not schedule an RFM re-segmentation", exc_info=True)
            return Response(
                {"detail": "لا يمكن جدولة إعادة الحساب الآن. حاول مرة أخرى."},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return Response(
            {"status": "scheduled", "task_id": async_result.id},
            status=status.HTTP_202_ACCEPTED,
        )

    @action(detail=False, methods=["get"], url_path="staff-account")
    def staff_account(self, request):
        """The signed-in user's own staff customer account, made if missing.

        What the till selects when a member of staff buys something for
        themselves; the invoice is then deducted from their next payroll run.
        """
        from apps.employees.staff_purchases import staff_customer_for_user

        customer = staff_customer_for_user(request.user)
        return Response(self.get_serializer(customer).data)

    @action(detail=True, methods=["post"], url_path="record-payment")
    def record_payment(self, request, pk=None):
        customer = self.get_object()
        session = RegisterSession.objects.filter(
            owner_key=f"user:{request.user.pk}",
            status=RegisterSession.Status.OPEN,
        ).first()
        if session is None:
            return Response(
                {"detail": "No open register session for this request owner."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return run_idempotent_request(
            request,
            lambda: self._record_payment(request, customer, session),
        )

    def _record_payment(self, request, customer, session):
        serializer = CustomerAccountPaymentSerializer(
            data=request.data,
            context={
                "customer": customer,
                "register_session": session,
                "request": request,
            },
        )
        serializer.is_valid(raise_exception=True)
        allocations = serializer.save()
        # Return the refreshed summary so the caller sees the new balance, plus a
        # representative payment so the client can print a proof-of-payment slip
        # (the collection splits across invoices; the proof is for the whole
        # amount, keyed on the oldest allocated payment).
        response = self.sales_summary(request, pk=customer.pk)
        if allocations:
            response.data["payment"] = {
                "id": allocations[0]["payment"].pk,
                "amount": str(serializer.validated_data["amount"]),
                "method": serializer.validated_data["method"],
            }
        return response

    @action(detail=True, methods=["post"], url_path="apply-credit")
    def apply_credit(self, request, pk=None):
        """Settle the customer's debts from the credit the shop holds for them.

        A collection does this on its own before taking any money; this is for
        the owner tidying an account in between — a customer who is owed money
        and has since bought on آجل should not be shown owing and owed at once.
        Answers with the refreshed summary.
        """
        customer = self.get_object()

        def apply():
            from apps.balances.customers import apply_customer_credit

            with transaction.atomic():
                apply_customer_credit(customer, actor=request.user)
            return self.sales_summary(request, pk=customer.pk)

        return run_idempotent_request(request, apply)

    @action(detail=True, methods=["get"], url_path="sales-summary")
    def sales_summary(self, request, pk=None):
        customer = self.get_object()
        # Every count/sum below reads one table with no joined multi-valued
        # relation, so they all fold into a single pass per table instead of the
        # thirteen round trips the separate .count()/.aggregate() calls cost.
        # ``transactional_sale_q`` is the same Q that ``OrderQuerySet.transactional``
        # is built from, so "which orders count as sales" still has one definition.
        transactional = transactional_sale_q()
        order_totals = self._customer_order_scope(customer).aggregate(
            invoice_count=Count("pk", filter=transactional),
            paid_invoice_count=Count(
                "pk", filter=transactional & Q(status=Order.Status.PAID)
            ),
            void_invoice_count=Count(
                "pk", filter=transactional & Q(status=Order.Status.VOID)
            ),
            quotation_count=Count(
                "pk", filter=Q(sale_type=Order.SaleType.QUOTATION)
            ),
            total_invoiced=Sum("total", filter=transactional),
            # Same value as the old "newest first, take created_at" read: the
            # ordering tie-break on -id cannot change which timestamp is largest.
            last_invoice_at=Max("created_at", filter=transactional),
        )
        is_return = Q(adjustment_type=OrderAdjustment.AdjustmentType.RETURN)
        is_void = Q(adjustment_type=OrderAdjustment.AdjustmentType.VOID)
        adjustment_totals = self._customer_adjustments(customer).aggregate(
            refund_count=Count("pk"),
            refund_total=Sum("amount"),
            return_count=Count("pk", filter=is_return),
            return_total=Sum("amount", filter=is_return),
            void_count=Count("pk", filter=is_void),
            void_total=Sum("amount", filter=is_void),
        )
        total_invoiced = _sum_money(order_totals["total_invoiced"])
        return_total = _sum_money(adjustment_totals["return_total"])
        void_total = _sum_money(adjustment_totals["void_total"])
        refund_total = _sum_money(adjustment_totals["refund_total"])
        last_invoice_at = order_totals["last_invoice_at"]
        # Outstanding receivable and the ceiling it is judged against, both
        # from the one definition in apps.customers.receivables — so the number
        # on this screen and the number the till refuses a sale over can never
        # drift apart. ``outstanding_balance`` keeps its meaning for every till
        # already reading it — what a collection will ask the customer for —
        # which is their debts net of any credit the shop holds for them.
        position = account_position(customer)
        balance = customer_balance(customer, position=position)
        assessment = assess_credit(customer, Decimal("0.00"), balance=balance)
        credit_limit = assessment.limit
        available_credit = assessment.available

        return Response(
            {
                "customer": customer.pk,
                "invoice_count": order_totals["invoice_count"],
                "paid_invoice_count": order_totals["paid_invoice_count"],
                "void_invoice_count": order_totals["void_invoice_count"],
                "quotation_count": order_totals["quotation_count"],
                "return_count": adjustment_totals["return_count"],
                "void_count": adjustment_totals["void_count"],
                "refund_count": adjustment_totals["refund_count"],
                "exchange_count": 0,
                "total_invoiced": _money_string(total_invoiced),
                "return_total": _money_string(return_total),
                "void_total": _money_string(void_total),
                "refund_total": _money_string(refund_total),
                "exchange_total": _money_string(Decimal("0.00")),
                "net_sales": _money_string(total_invoiced - refund_total),
                "outstanding_balance": _money_string(balance.owed_by_customer),
                # What the shop owes this customer once their debts are set
                # against it, and the two sides before netting — the screen
                # offers to apply the credit when both are non-zero.
                "credit_balance": _money_string(balance.owed_to_customer),
                "net_balance": _money_string(balance.net),
                "open_debts_total": _money_string(balance.open_debts),
                "unapplied_credit": _money_string(balance.unapplied_credit),
                "has_opening_balance": position.has_opening,
                "credit_limit": (
                    None if credit_limit is None else _money_string(credit_limit)
                ),
                "available_credit": (
                    None if available_credit is None else _money_string(available_credit)
                ),
                "last_invoice_at": last_invoice_at,
            }
        )

    @action(detail=True, methods=["get"])
    def orders(self, request, pk=None):
        customer = self.get_object()
        # The invoices tab renders the FULL order payload, so it needs the same
        # relations the sales endpoints load. Its own shorter prefetch list cost
        # ~14 queries per invoice (adjustment lines per line, option values per
        # line for variant.display_name, plus exchanges and applied discounts per
        # order); with_serializer_relations keeps that flat and in one place.
        queryset = (
            self._customer_orders(customer)
            .with_serializer_relations()
            .order_by("-created_at", "-id")
        )
        page = self.paginate_queryset(queryset)
        serializer = OrderSerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    @action(detail=True, methods=["get"])
    def adjustments(self, request, pk=None):
        customer = self.get_object()
        # ``variant.display_name`` falls back to a query per line whenever
        # option_values is not prefetched, so the returns tab paid one query per
        # adjustment line on top of the product prefetch.
        queryset = (
            self._customer_adjustments(customer)
            .select_related("order", "register_session", "created_by")
            .prefetch_related(
                "lines__variant__product",
                Prefetch(
                    "lines__variant__option_values",
                    queryset=VariantOptionValue.objects.select_related("option"),
                ),
            )
            .order_by("-created_at", "-id")
        )
        page = self.paginate_queryset(queryset)
        serializer = CustomerOrderAdjustmentSerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    def _customer_order_scope(self, customer):
        """The customer's orders this user may see, before any sale-type filter.

        Kept separate from ``_customer_orders`` so the summary can count sales
        and quotations in one aggregate over the same rows; the visibility rule
        stays in exactly one place.
        """
        queryset = customer.orders.all()
        if user_has_full_visibility(self.request.user):
            return queryset
        return queryset.filter(
            register_session__owner_key=f"user:{self.request.user.pk}",
        )

    def _customer_orders(self, customer):
        return self._customer_order_scope(customer).transactional()

    def _customer_adjustments(self, customer):
        queryset = OrderAdjustment.objects.filter(order__customer=customer)
        if user_has_full_visibility(self.request.user):
            return queryset
        return queryset.filter(
            order__register_session__owner_key=f"user:{self.request.user.pk}",
        )


class PaymentCardViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    viewsets.GenericViewSet,
):
    """Read + light-edit on captured cards. Cards are *created* by the payment
    flow, not the API, and reassigned through the explicit ``reassign`` action;
    only ``label`` / ``is_active`` are directly editable."""

    serializer_class = PaymentCardSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("customers.view_customer",),
        "retrieve": ("customers.view_customer",),
        "update": ("customers.change_customer",),
        "partial_update": ("customers.change_customer",),
        "reassign": ("customers.change_customer",),
    }
    queryset = PaymentCard.objects.select_related("customer").all()
    filterset_fields = ("customer", "is_active", "card_scheme")
    search_fields = ("masked_pan", "label", "card_scheme")
    ordering_fields = ("last_seen_at", "first_seen_at", "created_at")

    @action(detail=True, methods=["post"])
    def reassign(self, request, pk=None):
        card = self.get_object()
        customer_id = request.data.get("customer_id")
        if not customer_id:
            raise serializers.ValidationError(
                {"customer_id": "This field is required."}
            )
        customer = get_object_or_404(Customer, pk=customer_id)
        previous_customer_id = card.customer_id
        card.customer = customer
        card.save(update_fields=["customer", "updated_at"])
        record_domain_event(
            name="customers.payment_card.reassigned",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="payment_card",
            entity_id=card.pk,
            attributes={
                "from_customer_id": previous_customer_id,
                "to_customer_id": customer.pk,
            },
        )
        return Response(self.get_serializer(card).data)


def _sum_money(value):
    return (value or Decimal("0.00")).quantize(Decimal("0.01"))


def _money_string(value):
    return str(_sum_money(value))
