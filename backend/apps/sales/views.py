import logging

from django.db import IntegrityError, transaction
from django.db.models import Prefetch
from django.utils import timezone
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.catalog.models import VariantOptionValue
from apps.channels.services import require_active_sales_channel
from apps.core.idempotency import run_idempotent_request
from apps.core.discovery import request_is_relayed
from apps.core.models import ShopSettings
from apps.core.pagination import CreatedAtCursorPagination
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility
from apps.fraud.services import schedule_targeted_sweep
from .models import Order, RegisterCashMovement, RegisterSession
from .register_summary import cached_register_session_summary
from .serializers import (
    CheckoutSerializer,
    ConvertQuotationSerializer,
    CustomerInvoicePaymentSerializer,
    DiscountPreviewSerializer,
    OrderAssignCustomerSerializer,
    OrderExchangeInputSerializer,
    OrderListSerializer,
    OrderSerializer,
    OrderSessionSerializer,
    PublicInvoiceSerializer,
    OrderReturnSerializer,
    OrderVoidSerializer,
    RegisterCashMovementCreateSerializer,
    RegisterCashMovementSerializer,
    RegisterSessionCloseSerializer,
    RegisterSessionSerializer,
    RegisterSessionStartSerializer,
)

logger = logging.getLogger(__name__)


def _best_effort_print_step(description, step):
    """Run one of checkout's print steps so no printing fault can undo the sale.

    ``run_idempotent_request`` wraps the whole checkout — validation, stock
    deduction, payments *and* these steps — in a single transaction, so anything
    that raises here does not merely lose a receipt: it rolls the sale back and
    hands the cashier a 500 with the customer still standing there, again on
    every retry for as long as the fault lasts. Printing is a nice-to-have; the
    sale is not.

    The savepoint is what makes the ``except`` real. A step that fails on a
    *database* error — a statement timeout, a lost connection, a constraint hit
    by one of the bare ``.save()`` calls in the enqueue path — aborts the whole
    Postgres transaction, so catching it alone just defers the 500 to the next
    query. Rolling back to a savepoint leaves the sale intact and the
    transaction usable.
    """
    try:
        with transaction.atomic():
            return step()
    except Exception:
        logger.exception("Failed to enqueue %s; the sale is unaffected.", description)
        return None


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
        "exchange_items": ("sales.add_order",),
        "record_payment": ("sales.add_order",),
        "assign_customer": ("sales.add_order",),
        "outstanding": ("sales.view_order",),
        "convert": ("sales.add_order",),
        "reprint": ("sales.view_order", "printing.add_printjob"),
        # Returns-desk lookup: find ONE invoice by receipt number without
        # browsing the list. Visibility for the adjustment verbs above is widened
        # for this permission in get_queryset (the verbs keep needing add_order).
        "lookup": ("sales.process_return_lookup",),
    }
    queryset = Order.objects.with_serializer_relations()
    # Dict form (vs a plain tuple) so the date field also exposes range/day
    # lookups (created_at__gte / __lte / __date) — additive, existing exact
    # filters are unchanged. Lets the assistant ask for "today's sales" etc.
    filterset_fields = {
        "status": ["exact"],
        "sale_type": ["exact"],
        "customer": ["exact"],
        "register_session": ["exact"],
        "register_session__status": ["exact"],
        "sales_channel": ["exact"],
        "created_at": ["exact", "gte", "lte", "date"],
    }
    search_fields = (
        "receipt_number",
        "lines__variant__product__name",
        "lines__variant__sku",
        "lines__variant__barcode",
    )
    ordering_fields = ("created_at", "updated_at", "total", "receipt_number")

    def get_serializer_class(self):
        if self.action == "list":
            return OrderListSerializer
        return OrderSerializer

    def _list_summary_queryset(self, queryset):
        # The invoices list rows show a line COUNT and totals/profit (computed
        # from the lines) but never the line items themselves — the detail screen
        # re-fetches those on open. Keep a LIGHT `lines` prefetch (the rows only,
        # for total_cost / total_profit / the count) and drop the heavy per-line
        # variant / option / adjustment trees that were the bulk of the payload.
        return queryset.prefetch_related(None).prefetch_related(
            # lines + their adjustment_lines only: total_cost/profit and the
            # can_void/return/exchange affordances read them. The heavy
            # variant/product/option trees (the payload bulk) are dropped since
            # the rows never serialize the line items.
            "lines__adjustment_lines",
            "payments",
            "applied_discounts",
            "exchanges__replacement_order",
            "exchanges__created_by",
        )

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.action == "list":
            queryset = self._list_summary_queryset(queryset)
        product_id = self.request.query_params.get("product")
        variant_id = self.request.query_params.get("variant")
        if product_id:
            queryset = queryset.filter(lines__variant__product_id=product_id)
        if variant_id:
            queryset = queryset.filter(lines__variant_id=variant_id)
        if product_id or variant_id:
            queryset = queryset.distinct()
        if user_has_full_visibility(self.request.user):
            return queryset
        # A returns-desk operator may reach ONE invoice at a time (fetch it by id
        # or receipt number and adjust it) without seeing the whole list. The
        # ``list`` action stays session-scoped, so this never widens browsing.
        lookup_actions = {"retrieve", "return_items", "void", "exchange_items", "lookup"}
        if self.action in lookup_actions and self.request.user.has_perm(
            "sales.process_return_lookup"
        ):
            return queryset
        return queryset.filter(register_session__owner_key=register_session_owner_key(self.request))

    def _adjusted_order_response(self, order_pk, *, status_code):
        """Serialize a just-mutated order through the prefetch-rich queryset.

        Every adjustment action used to answer with the bare instance it had
        just ``refresh_from_db()``-ed — and that call *clears*
        ``_prefetched_objects_cache``, so the rich object ``get_object()``
        returned came back empty-handed. ``OrderSerializer`` then paid ~5
        queries per line for the response alone (option labels via
        ``variant.display_name``, plus ``can_void`` / ``can_return`` /
        ``can_exchange`` / ``returned_quantity`` / ``returnable_quantity``
        each re-reading ``adjustment_lines``). Re-reading instead of
        refreshing gives the same payload at a fixed query count.

        Uses ``self.queryset`` rather than ``get_queryset()``: the order is
        already authorized by the ``get_object()`` that opened the action, and
        ``get_queryset()``'s ``?product=`` / ``?variant=`` filters would
        happily filter the just-mutated order out of its own response.
        """
        return Response(
            OrderSerializer(
                self.queryset.get(pk=order_pk),
                context={"request": self.request},
            ).data,
            status=status_code,
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
        serializer.save(
            register_session=session,
            sales_channel=require_active_sales_channel(self.request),
        )

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
        # Serialize through the list/retrieve queryset so the response reads the
        # order's lines, variants, options, adjustments and payments from
        # prefetches instead of firing a query per line (the checkout response
        # N+1). The bare `order` is kept for the print/kitchen steps below.
        response_data = OrderSerializer(
            self.queryset.get(pk=order.pk),
            context={"request": request},
        ).data

        claimed_print_job = self._claim_checkout_invoice_print_job(
            order,
            print_action_serializer,
            request,
        )
        if claimed_print_job is not None:
            from apps.printing.serializers import PrintJobSerializer

            response_data["print_job"] = PrintJobSerializer(claimed_print_job).data

        # Kitchen chits are enqueued (idempotently, gated on the shop setting)
        # and returned QUEUED. The printing device claims and prints the chits
        # for the stations it actually serves; jobs for other stations stay
        # queued for those devices (or a manual reprint).
        kitchen_print_jobs = self._enqueue_checkout_kitchen_print_jobs(order)
        if kitchen_print_jobs:
            from apps.printing.serializers import PrintJobSerializer

            response_data["kitchen_print_jobs"] = PrintJobSerializer(
                kitchen_print_jobs,
                many=True,
            ).data

        return Response(response_data, status=status.HTTP_201_CREATED)

    @action(detail=False, methods=["post"], url_path="discount-preview")
    def discount_preview(self, request):
        serializer = DiscountPreviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return Response(serializer.preview_data)

    @action(detail=False, methods=["get"])
    def outstanding(self, request):
        # Debt invoices (آجل) that still carry a balance, oldest first — the
        # receivables list for collection. Owner-scoped for cashiers.
        queryset = (
            self.filter_queryset(self.get_queryset())
            .open_credit()
            .order_by("created_at", "id")
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

    @action(detail=True, methods=["post"], url_path="record-payment")
    def record_payment(self, request, pk=None):
        session = self._open_register_session(request)
        if session is None:
            return Response(
                {"detail": "No open register session for this request owner."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return run_idempotent_request(
            request,
            lambda: self._record_payment(request, session),
        )

    def _record_payment(self, request, session):
        order = self.get_object()
        serializer = CustomerInvoicePaymentSerializer(
            data=request.data,
            context={
                "order": order,
                "register_session": session,
                "request": request,
            },
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return self._adjusted_order_response(
            order.pk,
            status_code=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"], url_path="assign-customer")
    def assign_customer(self, request, pk=None):
        # No register session needed — no money moves; this only fixes WHO owes
        # a not-yet-collected debt invoice.
        return run_idempotent_request(
            request,
            lambda: self._assign_customer(request),
        )

    def _assign_customer(self, request):
        order = self.get_object()
        serializer = OrderAssignCustomerSerializer(
            data=request.data,
            context={"order": order, "request": request},
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return self._adjusted_order_response(
            order.pk,
            status_code=status.HTTP_200_OK,
        )

    @action(detail=True, methods=["post"])
    def convert(self, request, pk=None):
        session = self._open_register_session(request)
        if session is None:
            return Response(
                {"detail": "No open register session for this request owner."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return run_idempotent_request(
            request,
            lambda: self._convert(request, session),
        )

    def _convert(self, request, session):
        quotation = self.get_object()
        serializer = ConvertQuotationSerializer(
            data=request.data,
            context={
                "quotation": quotation,
                "register_session": session,
                "request": request,
            },
        )
        serializer.is_valid(raise_exception=True)
        new_order = serializer.save()
        return self._adjusted_order_response(
            new_order.pk,
            status_code=status.HTTP_201_CREATED,
        )

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
        schedule_targeted_sweep()
        return self._adjusted_order_response(
            order.pk,
            status_code=status.HTTP_200_OK,
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
        schedule_targeted_sweep()
        return self._adjusted_order_response(
            order.pk,
            status_code=status.HTTP_200_OK,
        )

    @action(detail=True, methods=["post"], url_path="exchange-items")
    def exchange_items(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._exchange_items(request),
        )

    def _exchange_items(self, request):
        order = self.get_object()
        session = self._open_register_session(request)
        if session is None:
            raise serializers.ValidationError(
                {"detail": "No open register session for this request owner."}
            )
        serializer = OrderExchangeInputSerializer(
            data=request.data,
            context={
                "order": order,
                "request": request,
                "adjustment_register_session": session,
            },
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        schedule_targeted_sweep()
        return self._adjusted_order_response(
            order.pk,
            status_code=status.HTTP_200_OK,
        )

    @action(detail=False, methods=["get"])
    def lookup(self, request):
        """Returns-desk: fetch a single invoice by its receipt number. Visibility
        is widened by ``sales.process_return_lookup`` in ``get_queryset`` so the
        operator can reach an invoice they did not ring up, without listing all
        invoices."""
        receipt_number = (request.query_params.get("receipt") or "").strip()
        if not receipt_number:
            raise serializers.ValidationError(
                {"receipt": "A receipt number is required."}
            )
        order = self.get_queryset().filter(receipt_number=receipt_number).first()
        if order is None:
            return Response(
                {"detail": "No invoice matches that receipt number."},
                status=status.HTTP_404_NOT_FOUND,
            )
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

        # Best-effort: a receipt-printing fault must never fail or roll back a
        # completed, paid sale (the kitchen enqueue below is the same deal).
        return _best_effort_print_step(
            f"receipt print job for order {order.pk}",
            lambda: self._claim_invoice_print_job(order, action_serializer, request),
        )

    def _claim_invoice_print_job(self, order, action_serializer, request):
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

    def _enqueue_checkout_kitchen_print_jobs(self, order):
        from apps.printing.services import enqueue_kitchen_print_jobs

        # Best-effort: a kitchen-printing misconfiguration must never fail or
        # roll back a completed, paid sale (mirrors the receipt enqueue).
        jobs = _best_effort_print_step(
            f"kitchen tickets for order {order.pk}",
            lambda: enqueue_kitchen_print_jobs(order.pk),
        )
        return jobs or []


class PublicInvoiceView(mixins.RetrieveModelMixin, viewsets.GenericViewSet):
    serializer_class = PublicInvoiceSerializer
    permission_classes = [AllowAny]
    authentication_classes = []
    lookup_field = "public_token"
    lookup_url_kwarg = "token"

    queryset = Order.objects.select_related("customer").prefetch_related(
        "lines__variant__product",
        # This page builds its own queryset rather than reusing
        # ``OrderViewSet``'s, so the option-value prefetch that one carries has
        # to be repeated here: every line renders ``variant.display_name``,
        # whose ``option_values_label`` fallback queries once per line for the
        # unnamed variants a normal shop sells almost exclusively.
        Prefetch(
            "lines__variant__option_values",
            queryset=VariantOptionValue.objects.select_related("option"),
        ),
    )

    def get_queryset(self):
        if not request_is_relayed(self.request):
            return Order.objects.none()
        if not ShopSettings.load().enable_online_invoices:
            return Order.objects.none()
        # Hide only transient standard carts; credit (debt) invoices and
        # quotations are shareable documents even while OPEN.
        return super().get_queryset().exclude(
            status=Order.Status.OPEN,
            sale_type=Order.SaleType.STANDARD,
        )


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
        "summary": ("sales.view_registersession",),
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
    # Every list this viewset serves (sessions, a session's orders, its cash
    # movements) is newest-first over a drawer that may still be selling, so all
    # three page by cursor: an offset page 2 would re-serve the boundary rows and
    # drop whatever was written since page 1.
    pagination_class = CreatedAtCursorPagination

    def get_queryset(self):
        queryset = super().get_queryset()
        if user_has_full_visibility(self.request.user):
            return queryset
        return queryset.filter(owner_key=register_session_owner_key(self.request))

    def get_owner_queryset(self):
        return super().get_queryset().filter(owner_key=register_session_owner_key(self.request))

    @action(detail=True, methods=["get"])
    def orders(self, request, pk=None):
        session = self.get_object()
        # The strip renders row summaries + a line count + a returnable flag, not
        # the line items. Prefetch the lines (with their adjustment_lines) so the
        # count, totals/profit AND the returnable flag all read from cache — the
        # flag's returnable_quantity otherwise fired an adjustment-line query per
        # line (the endpoint's N+1) — then serialize the trimmed
        # OrderSessionSerializer instead of the full line items.
        orders = (
            session.orders.select_related("customer", "register_session")
            .prefetch_related("lines__adjustment_lines", "payments")
            .order_by("-created_at")
        )
        customer_id = request.query_params.get("customer")
        if customer_id:
            orders = orders.filter(customer_id=customer_id)
        page = self.paginate_queryset(orders)
        if page is not None:
            serializer = OrderSessionSerializer(
                page,
                many=True,
                context={"request": request},
            )
            return self.get_paginated_response(serializer.data)
        return Response(
            OrderSessionSerializer(
                orders, many=True, context={"request": request}
            ).data,
        )

    @action(detail=True, methods=["get"])
    def summary(self, request, pk=None):
        """Full end-of-shift summary across all payment methods plus a
        sales-by-category breakdown and cash reconciliation. Single source of
        truth for the manager session view and the printable Z-Report."""
        session = self.get_object()
        return Response(cached_register_session_summary(session))

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
