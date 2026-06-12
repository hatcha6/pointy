from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.idempotency import run_idempotent_request
from apps.core.discovery import request_is_relayed
from apps.core.models import ShopSettings
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_is_manager
from apps.fraud.services import schedule_targeted_sweep
from .models import Order, RegisterCashMovement, RegisterSession
from .serializers import (
    CheckoutSerializer,
    DiscountPreviewSerializer,
    OrderSerializer,
    PublicInvoiceSerializer,
    OrderReturnSerializer,
    OrderVoidSerializer,
    RegisterCashMovementCreateSerializer,
    RegisterCashMovementSerializer,
    RegisterSessionCloseSerializer,
    RegisterSessionSerializer,
    RegisterSessionStartSerializer,
)


class OrderViewSet(
    mixins.CreateModelMixin,
    mixins.RetrieveModelMixin,
    mixins.ListModelMixin,
    viewsets.GenericViewSet,
):
    # Orders are append-only: they may be created and then only adjusted through
    # the audited ``void`` and ``return_items`` actions. Direct PATCH/PUT/DELETE
    # is intentionally not exposed so a sale (and its audit trail) can never be
    # silently edited or erased — including by a manager, who is otherwise
    # granted every ``sales`` permission.
    serializer_class = OrderSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("sales.view_order",),
        "retrieve": ("sales.view_order",),
        "create": ("sales.add_order",),
        "checkout": ("sales.add_order",),
        "discount_preview": ("sales.add_order",),
        "return_items": ("sales.add_order",),
        "void": ("sales.add_order",),
        "reprint": ("sales.view_order", "printing.add_printjob"),
    }
    queryset = Order.objects.select_related("customer", "register_session").prefetch_related(
        "lines__variant__product",
        "payments",
    )
    filterset_fields = (
        "status",
        "customer",
        "register_session",
        "register_session__status",
    )
    search_fields = (
        "receipt_number",
        "lines__variant__product__name",
        "lines__variant__sku",
        "lines__variant__barcode",
    )
    ordering_fields = ("created_at", "updated_at", "total", "receipt_number")

    def get_queryset(self):
        queryset = super().get_queryset()
        product_id = self.request.query_params.get("product")
        variant_id = self.request.query_params.get("variant")
        if product_id:
            queryset = queryset.filter(lines__variant__product_id=product_id)
        if variant_id:
            queryset = queryset.filter(lines__variant_id=variant_id)
        if product_id or variant_id:
            queryset = queryset.distinct()
        if user_is_manager(self.request.user):
            return queryset
        return queryset.filter(
            register_session__owner_key=register_session_owner_key(self.request)
        )

    def _open_register_session(self, request):
        return RegisterSession.objects.filter(
            owner_key=register_session_owner_key(request),
            status=RegisterSession.Status.OPEN,
        ).first()

    def perform_create(self, serializer):
        session = self._open_register_session(self.request)
        if session is None:
            raise serializers.ValidationError(
                {"detail": "No open register session for this request owner."}
            )
        serializer.save(register_session=session)

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(OrderViewSet, self).create(request, *args, **kwargs),
        )

    @action(detail=False, methods=["post"])
    def checkout(self, request):
        session = self._open_register_session(request)
        if session is None:
            return Response(
                {"detail": "No open register session for this request owner."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        return run_idempotent_request(
            request,
            lambda: self._checkout(request, session),
        )

    def _checkout(self, request, session):
        print_action_serializer = self._invoice_print_action_serializer(request)
        serializer = CheckoutSerializer(
            data=request.data,
            context={"register_session": session, "request": request},
        )
        serializer.is_valid(raise_exception=True)
        order = serializer.save()
        response_data = OrderSerializer(order, context={"request": request}).data

        claimed_print_job = self._claim_checkout_invoice_print_job(
            order,
            print_action_serializer,
            request,
        )
        if claimed_print_job is not None:
            from apps.printing.serializers import PrintJobSerializer

            response_data["print_job"] = PrintJobSerializer(claimed_print_job).data

        return Response(response_data, status=status.HTTP_201_CREATED)

    @action(detail=False, methods=["post"], url_path="discount-preview")
    def discount_preview(self, request):
        serializer = DiscountPreviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return Response(serializer.preview_data)

    @action(detail=True, methods=["post"])
    def reprint(self, request, pk=None):
        from apps.printing.serializers import PrintJobAgentActionSerializer
        from apps.printing.serializers import PrintJobSerializer
        from apps.printing.services import claim_print_job, enqueue_manual_receipt_reprint

        job = enqueue_manual_receipt_reprint(self.get_object(), user=request.user)
        if request.data:
            action_serializer = PrintJobAgentActionSerializer(data=request.data)
            action_serializer.is_valid(raise_exception=True)
            job = claim_print_job(
                job,
                action_serializer.validated_data["agent"],
                user=request.user,
                printer_endpoint=action_serializer.validated_data.get(
                    "printer_endpoint",
                    {},
                ),
            )
        return Response(PrintJobSerializer(job).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"], url_path="return-items")
    def return_items(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._return_items(request),
        )

    def _return_items(self, request):
        order = self.get_object()
        serializer = OrderReturnSerializer(
            data=request.data,
            context={
                "order": order,
                "request": request,
                "adjustment_register_session": self._open_register_session(request),
            },
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        order.refresh_from_db()
        schedule_targeted_sweep()
        return Response(
            OrderSerializer(order, context={"request": request}).data,
            status=status.HTTP_200_OK,
        )

    @action(detail=True, methods=["post"])
    def void(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._void(request),
        )

    def _void(self, request):
        order = self.get_object()
        serializer = OrderVoidSerializer(
            data=request.data,
            context={
                "order": order,
                "request": request,
                "adjustment_register_session": self._open_register_session(request),
            },
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        order.refresh_from_db()
        schedule_targeted_sweep()
        return Response(
            OrderSerializer(order, context={"request": request}).data,
            status=status.HTTP_200_OK,
        )

    def _invoice_print_action_serializer(self, request):
        print_action = request.data.get("print_invoice")
        if print_action in (None, False):
            return None
        if not isinstance(print_action, dict):
            raise serializers.ValidationError(
                {"print_invoice": "Print invoice details must be an object."}
            )

        from apps.printing.serializers import PrintJobAgentActionSerializer

        action_serializer = PrintJobAgentActionSerializer(data=print_action)
        action_serializer.is_valid(raise_exception=True)
        return action_serializer

    def _claim_checkout_invoice_print_job(self, order, action_serializer, request):
        if action_serializer is None:
            return None

        from apps.core.models import ShopSettings
        from apps.printing.services import (
            claim_print_job,
            enqueue_manual_receipt_reprint,
            enqueue_receipt_print_job,
        )

        if ShopSettings.load().auto_print_receipts:
            job = enqueue_receipt_print_job(order.pk)
        else:
            job = enqueue_manual_receipt_reprint(order, user=request.user)

        if job is None:
            return None

        try:
            return claim_print_job(
                job,
                action_serializer.validated_data["agent"],
                user=request.user,
                printer_endpoint=action_serializer.validated_data.get(
                    "printer_endpoint",
                    {},
                ),
            )
        except ValueError:
            return None


class PublicInvoiceView(mixins.RetrieveModelMixin, viewsets.GenericViewSet):
    serializer_class = PublicInvoiceSerializer
    permission_classes = [AllowAny]
    authentication_classes = []
    lookup_field = "public_token"
    lookup_url_kwarg = "token"

    queryset = Order.objects.select_related("customer").prefetch_related(
        "lines__variant__product",
    )

    def get_queryset(self):
        if not request_is_relayed(self.request):
            return Order.objects.none()
        if not ShopSettings.load().enable_online_invoices:
            return Order.objects.none()
        return super().get_queryset().exclude(status=Order.Status.OPEN)


def register_session_owner_key(request):
    if request.user.is_authenticated:
        return f"user:{request.user.pk}"
    return "anonymous"


def register_session_owner(request):
    if request.user.is_authenticated:
        return request.user
    return None


class RegisterSessionViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = RegisterSessionSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("sales.view_registersession",),
        "retrieve": ("sales.view_registersession",),
        "orders": ("sales.view_registersession", "sales.view_order"),
        "cash_movements": (
            "sales.view_registersession",
            "sales.view_registercashmovement",
        ),
        "current": ("sales.view_registersession",),
        "start": ("sales.add_registersession",),
        "close": ("sales.change_registersession",),
        "pay_in": (
            "sales.change_registersession",
            "sales.add_registercashmovement",
        ),
        "pay_out": (
            "sales.change_registersession",
            "sales.add_registercashmovement",
        ),
    }
    queryset = RegisterSession.objects.select_related("owner")

    def get_queryset(self):
        queryset = super().get_queryset()
        if user_is_manager(self.request.user):
            return queryset
        return queryset.filter(owner_key=register_session_owner_key(self.request))

    def get_owner_queryset(self):
        return super().get_queryset().filter(
            owner_key=register_session_owner_key(self.request)
        )

    @action(detail=True, methods=["get"])
    def orders(self, request, pk=None):
        session = self.get_object()
        orders = (
            session.orders.select_related("customer", "register_session")
            .prefetch_related("lines__variant__product", "payments")
            .order_by("-created_at")
        )
        customer_id = request.query_params.get("customer")
        if customer_id:
            orders = orders.filter(customer_id=customer_id)
        page = self.paginate_queryset(orders)
        if page is not None:
            serializer = OrderSerializer(
                page,
                many=True,
                context={"request": request},
            )
            return self.get_paginated_response(serializer.data)
        return Response(
            OrderSerializer(orders, many=True, context={"request": request}).data,
        )

    @action(detail=True, methods=["get"], url_path="cash-movements")
    def cash_movements(self, request, pk=None):
        session = self.get_object()
        movements = session.cash_movements.select_related(
            "created_by",
            "register_session",
        )
        page = self.paginate_queryset(movements)
        if page is not None:
            serializer = RegisterCashMovementSerializer(page, many=True)
            return self.get_paginated_response(serializer.data)
        return Response(RegisterCashMovementSerializer(movements, many=True).data)

    @action(detail=False, methods=["get"])
    def current(self, request):
        session = self.get_owner_queryset().filter(status=RegisterSession.Status.OPEN).first()
        if session is None:
            return Response(status=status.HTTP_204_NO_CONTENT)
        return Response(self.get_serializer(session).data)

    @action(detail=False, methods=["post"])
    def start(self, request):
        return run_idempotent_request(
            request,
            lambda: self._start(request),
        )

    def _start(self, request):
        serializer = RegisterSessionStartSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        owner_key = register_session_owner_key(request)
        defaults = {
            "owner": register_session_owner(request),
            "opening_cash": serializer.validated_data.get("opening_cash", 0),
        }

        try:
            with transaction.atomic():
                session = (
                    RegisterSession.objects.select_for_update()
                    .filter(owner_key=owner_key, status=RegisterSession.Status.OPEN)
                    .first()
                )
                reused_existing_session = session is not None
                if session is None:
                    session = RegisterSession.objects.create(owner_key=owner_key, **defaults)
        except IntegrityError:
            session = RegisterSession.objects.get(
                owner_key=owner_key,
                status=RegisterSession.Status.OPEN,
            )
            reused_existing_session = True

        record_domain_event(
            name="sales.register_session.started",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="register_session",
            entity_id=session.pk,
            attributes={
                "owner_key": owner_key,
                "existing_open_session_reused": reused_existing_session,
            },
            metrics={"opening_cash": float(session.opening_cash)},
        )

        return Response(self.get_serializer(session).data)

    @action(detail=True, methods=["post"], url_path="pay-in")
    def pay_in(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._create_cash_movement(
                request,
                RegisterCashMovement.MovementType.PAY_IN,
            ),
        )

    @action(detail=True, methods=["post"], url_path="pay-out")
    def pay_out(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._create_cash_movement(
                request,
                RegisterCashMovement.MovementType.PAY_OUT,
            ),
        )

    def _create_cash_movement(self, request, movement_type):
        session = self.get_object()
        if session.status != RegisterSession.Status.OPEN:
            return Response(
                {"detail": "Register session is already closed."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        serializer = RegisterCashMovementCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        movement = RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=movement_type,
            amount=serializer.validated_data["amount"],
            reason=serializer.validated_data["reason"],
            created_by=register_session_owner(request),
        )
        record_domain_event(
            name="sales.register_cash_movement.created",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=(
                AnalyticsEvent.Severity.WARNING
                if movement_type == RegisterCashMovement.MovementType.PAY_OUT
                else AnalyticsEvent.Severity.INFO
            ),
            user=request.user,
            entity_type="register_session",
            entity_id=session.pk,
            attributes={
                "cash_movement_id": movement.pk,
                "movement_type": movement_type,
                "reason_present": bool(movement.reason),
            },
            metrics={"amount": float(movement.amount)},
        )
        if movement_type == RegisterCashMovement.MovementType.PAY_OUT:
            schedule_targeted_sweep()
        return Response(
            RegisterCashMovementSerializer(movement).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def close(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._close(request),
        )

    def _close(self, request):
        session = self.get_object()
        if session.status != RegisterSession.Status.OPEN:
            return Response(
                {"detail": "Register session is already closed."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        serializer = RegisterSessionCloseSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        for field, value in serializer.validated_data.items():
            setattr(session, field, value)
        # ``closing_cash`` stores the full drawer total: the manually entered
        # cash plus the value of the counted denominations.
        session.closing_cash = session.closing_cash + session.denomination_total
        session.status = RegisterSession.Status.CLOSED
        session.closed_at = timezone.now()
        session.save(
            update_fields=[
                "status",
                "closing_cash",
                "count_025",
                "count_050",
                "count_075",
                "count_100",
                "closed_at",
                "updated_at",
            ]
        )
        record_domain_event(
            name="sales.register_session.closed",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="register_session",
            entity_id=session.pk,
            attributes={
                "owner_key": session.owner_key,
                "cash_counts_present": any(
                    getattr(session, field) > 0
                    for field in (
                        "count_025",
                        "count_050",
                        "count_075",
                        "count_100",
                    )
                ),
            },
            metrics={
                "opening_cash": float(session.opening_cash),
                "closing_cash": float(session.closing_cash),
            },
        )
        # Closing the register is when cash shortages become visible — sweep
        # immediately so the owner sees a finding while the shift is fresh.
        schedule_targeted_sweep()

        return Response(self.get_serializer(session).data)
