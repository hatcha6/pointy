from decimal import Decimal

from django.db.models import Count, Sum
from django.shortcuts import get_object_or_404
from rest_framework import mixins, serializers, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_is_manager
from apps.sales.models import Order, OrderAdjustment
from apps.sales.serializers import OrderSerializer
from .models import Customer, PaymentCard
from .serializers import (
    CustomerOrderAdjustmentSerializer,
    CustomerSerializer,
    PaymentCardSerializer,
)
from .services import merge_customers


class CustomerViewSet(viewsets.ModelViewSet):
    serializer_class = CustomerSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
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
    }
    queryset = Customer.objects.all()
    filterset_fields = ("is_active", "gender", "marketing_consent", "is_auto_created")
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
    )

    def get_queryset(self):
        # The Count annotation adds a GROUP BY, which drops the model's default
        # ordering (and trips DRF's pagination warning), so re-apply it explicitly.
        queryset = (
            super()
            .get_queryset()
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

    @action(detail=True, methods=["get"], url_path="sales-summary")
    def sales_summary(self, request, pk=None):
        customer = self.get_object()
        orders = self._customer_orders(customer)
        adjustments = self._customer_adjustments(customer)
        return_adjustments = adjustments.filter(
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
        )
        void_adjustments = adjustments.filter(
            adjustment_type=OrderAdjustment.AdjustmentType.VOID,
        )
        total_invoiced = _sum_money(orders.aggregate(total=Sum("total"))["total"])
        return_total = _sum_money(
            return_adjustments.aggregate(total=Sum("amount"))["total"],
        )
        void_total = _sum_money(
            void_adjustments.aggregate(total=Sum("amount"))["total"],
        )
        refund_total = _sum_money(adjustments.aggregate(total=Sum("amount"))["total"])
        last_invoice_at = (
            orders.order_by("-created_at", "-id")
            .values_list("created_at", flat=True)
            .first()
        )

        return Response(
            {
                "customer": customer.pk,
                "invoice_count": orders.count(),
                "paid_invoice_count": orders.filter(status=Order.Status.PAID).count(),
                "void_invoice_count": orders.filter(status=Order.Status.VOID).count(),
                "return_count": return_adjustments.count(),
                "void_count": void_adjustments.count(),
                "refund_count": adjustments.count(),
                "exchange_count": 0,
                "total_invoiced": _money_string(total_invoiced),
                "return_total": _money_string(return_total),
                "void_total": _money_string(void_total),
                "refund_total": _money_string(refund_total),
                "exchange_total": _money_string(Decimal("0.00")),
                "net_sales": _money_string(total_invoiced - refund_total),
                "last_invoice_at": last_invoice_at,
            }
        )

    @action(detail=True, methods=["get"])
    def orders(self, request, pk=None):
        customer = self.get_object()
        queryset = (
            self._customer_orders(customer)
            .select_related("customer", "register_session")
            .prefetch_related("lines__variant__product", "payments")
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
        queryset = (
            self._customer_adjustments(customer)
            .select_related("order", "register_session", "created_by")
            .prefetch_related("lines__variant__product")
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

    def _customer_orders(self, customer):
        queryset = customer.orders.exclude(status=Order.Status.OPEN)
        if user_is_manager(self.request.user):
            return queryset
        return queryset.filter(
            register_session__owner_key=f"user:{self.request.user.pk}",
        )

    def _customer_adjustments(self, customer):
        queryset = OrderAdjustment.objects.filter(order__customer=customer)
        if user_is_manager(self.request.user):
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
