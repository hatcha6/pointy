import logging

import django_filters
from django.db import IntegrityError, transaction
from django.db.models import Prefetch
from django.utils import timezone
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.catalog.models import ProductVariant, VariantOptionValue
from apps.channels.services import require_active_sales_channel
from apps.core.idempotency import run_idempotent_request
from apps.core.discovery import request_is_relayed
from apps.core.models import ShopSettings
from apps.core.pagination import CreatedAtCursorPagination
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility
from apps.fraud.services import schedule_targeted_sweep
from .models import (
    Order,
    OrderLine,
    RegisterCashMovement,
    RegisterProfile,
    RegisterSession,
)
from .register_summary import cached_register_session_summary
from .serializers import (
    CheckoutSerializer,
    ConvertQuotationSerializer,
    CustomerInvoicePaymentSerializer,
    DiscountPreviewSerializer,
    OrderAssignCustomerSerializer,
    OrderDueDateSerializer,
    OrderExchangeInputSerializer,
    OrderListSerializer,
    OrderSerializer,
    OrderSessionSerializer,
    RegisterProfileSerializer,
    PublicInvoiceSerializer,
    OrderReturnSerializer,
    OrderVoidSerializer,
    RegisterCashMovementCreateSerializer,
    RegisterCashMovementSerializer,
    RegisterSessionCloseSerializer,
    RegisterSessionSerializer,
    LineCostRequestSerializer,
    RegisterSessionStartSerializer,
)
from .services import money, sale_cost_basis, selling_warehouse_id

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


class OrderFilter(django_filters.FilterSet):
    """Order list filters.

    A ``FilterSet`` rather than the plain ``filterset_fields`` dict so
    ``cashier`` can be spelled the way the serializer spells it while filtering
    through the drawer session that actually holds it. Declaring it here also
    keeps the validation — ``?cashier=abc`` is a 400, not a silently unfiltered
    list that the client still labels as filtered — and the AI tool registry
    reads ``base_filters``, so the assistant gains the filter with it.
    """

    # Whose sales these are, by the person rather than by the shift: reviewing
    # one cashier's history should not mean picking their sessions one at a
    # time. ``get_queryset``'s own scoping still applies underneath, so a
    # cashier passing someone else's id gets nothing back, not someone else's
    # sales.
    cashier = django_filters.NumberFilter(field_name="register_session__owner")

    class Meta:
        model = Order
        # Dict form (vs a plain tuple) so the date field also exposes range/day
        # lookups (created_at__gte / __lte / __date) — additive, existing exact
        # filters are unchanged. Lets the assistant ask for "today's sales" etc.
        fields = {
            "status": ["exact"],
            "sale_type": ["exact"],
            "customer": ["exact"],
            "register_session": ["exact"],
            "register_session__status": ["exact"],
            "sales_channel": ["exact"],
            "created_at": ["exact", "gte", "lte", "date"],
        }


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
        # Rescheduling a debt changes no money, but it changes when the shop
        # chases it — a manager decision, not a till one.
        "due_date": ("sales.change_order",),
        "outstanding": ("sales.view_order",),
        "convert": ("sales.add_order",),
        "reprint": ("sales.view_order", "printing.add_printjob"),
        # Returns-desk lookup: find ONE invoice by receipt number without
        # browsing the list. Visibility for the adjustment verbs above is widened
        # for this permission in get_queryset (the verbs keep needing add_order).
        "lookup": ("sales.process_return_lookup",),
        # What the cart cost the shop. Its own permission, because it is the
        # most sensitive number a shop has and a cashier does not get it by
        # virtue of being able to sell.
        "line_costs": ("sales.view_till_cost",),
    }
    queryset = Order.objects.with_serializer_relations()
    filterset_class = OrderFilter
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
        # re-fetches those on open. `with_list_serializer_relations` is the one
        # definition of what those rows read (a LIGHT `lines` prefetch, dropping
        # the heavy per-line variant/option trees that were the payload bulk);
        # the register-session strip serializes the same rows and shares it.
        return queryset.prefetch_related(None).with_list_serializer_relations()

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.action != "retrieve":
            # An account entry's carrier is not an invoice: it has no lines, was
            # never sold, and is settled and retracted through its balance
            # entry. It stays readable by id (a payment on it links here) but
            # never appears in an invoice list or answers an invoice action.
            queryset = queryset.exclude(sale_type=Order.SaleType.ACCOUNT_ENTRY)
        if self.action == "list":
            queryset = self._list_summary_queryset(queryset)
        product_id = self.request.query_params.get("product")
        variant_id = self.request.query_params.get("variant")
        # Semi-joins, not a JOIN + DISTINCT: the product page's "recent sales"
        # asks for every order containing the product, and joining every one
        # of its lines then de-duplicating the whole result (and COUNTing it
        # the same way for the page header) is a sort over the product's entire
        # sales history — the field measured 3 to 17 s on a popular item. An
        # ``id IN (lines of this product)`` lets the planner walk the line
        # index and stop at the page.
        if product_id:
            queryset = queryset.filter(
                id__in=OrderLine.objects.filter(
                    variant__product_id=product_id
                ).values("order_id")
            )
        if variant_id:
            queryset = queryset.filter(
                id__in=OrderLine.objects.filter(variant_id=variant_id).values(
                    "order_id"
                )
            )
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

    @action(detail=False, methods=["post"], url_path="line-costs")
    def line_costs(self, request):
        """What the variants in a cart cost, per base unit.

        A POST rather than a GET because a cart is a list and a till's cart can
        be long enough to trouble a query string; and its own endpoint rather
        than a field on the catalog, because the catalog list serves fifty
        products a page to everyone, while this is a handful of variants for
        the few people allowed to see them.

        The figure is the valuation ledger's, which is the same basis the
        loss guard compares an asking price against — so a cashier who is
        shown 12.00 and refused a sale at 11.50 is looking at the number that
        refused them, not a different one.
        """
        serializer = LineCostRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        variants = list(
            ProductVariant.objects.filter(
                pk__in=serializer.validated_data["variants"]
            )
        )
        costs = sale_cost_basis(
            variants, warehouse=selling_warehouse_id(request)
        )
        return Response(
            {
                "costs": {
                    str(variant_id): str(money(cost))
                    for variant_id, cost in costs.items()
                }
            }
        )

    @action(detail=False, methods=["post"], url_path="discount-preview")
    def discount_preview(self, request):
        # The request rides along so the preview prices a repriced line the
        # same way checkout will. Without it the cashier would see one total
        # while typing and a different one on the payment screen, which is
        # the kind of disagreement that makes a till untrustworthy.
        serializer = DiscountPreviewSerializer(
            data=request.data, context={"request": request}
        )
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

    @action(detail=True, methods=["post"], url_path="due-date")
    def due_date(self, request, pk=None):
        # No register session and no money movement: this moves when a debt is
        # settled, never how much is owed.
        return run_idempotent_request(
            request,
            lambda: self._set_due_date(request),
        )

    def _set_due_date(self, request):
        order = self.get_object()
        serializer = OrderDueDateSerializer(
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
            order_clears_auto_print_floor,
        )

        shop_settings = ShopSettings.load()
        if shop_settings.auto_print_receipts and order_clears_auto_print_floor(
            order,
            shop_settings,
        ):
            job = enqueue_receipt_print_job(order.pk)
        else:
            # The till asked for this print by name: either auto-print is off
            # and the cashier ticked the box, or the sale is under the shop's
            # auto-print floor and they wanted a slip anyway. A floor decides
            # what prints on its own, never what a cashier may ask for.
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
        # quotations are shareable documents even while OPEN. An account entry
        # is never an invoice to share: it has nothing on it but a figure.
        return (
            super()
            .get_queryset()
            .exclude(status=Order.Status.OPEN, sale_type=Order.SaleType.STANDARD)
            .exclude(sale_type=Order.SaleType.ACCOUNT_ENTRY)
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
        # the line items, so it serializes the trimmed OrderSessionSerializer.
        # That is `OrderListSerializer` plus one flag, so it reads exactly what
        # the invoices list reads and takes the same shared prefetch shape — a
        # hand-rolled subset here cost `applied_discounts` and `exchanges` (and
        # the `sales_channel` FK) once per order in the page.
        orders = session.orders.with_list_serializer_relations().order_by(
            "-created_at"
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
                {
                    "detail": "Register session is already closed.",
                    # Machine-readable because the client has to *branch* on
                    # this, not just print it: a till holding a stale session id
                    # should re-sync and carry on, and it cannot match on an
                    # English sentence in a shop running Arabic. On 5 September
                    # 2026 a cashier met this 21 times in 35 seconds at 02:13
                    # because nothing distinguished it from any other refusal.
                    "code": "register_session_already_closed",
                },
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
                {
                    "detail": "Register session is already closed.",
                    # Machine-readable because the client has to *branch* on
                    # this, not just print it: a till holding a stale session id
                    # should re-sync and carry on, and it cannot match on an
                    # English sentence in a shop running Arabic. On 5 September
                    # 2026 a cashier met this 21 times in 35 seconds at 02:13
                    # because nothing distinguished it from any other refusal.
                    "code": "register_session_already_closed",
                },
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


class RegisterProfileViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    viewsets.GenericViewSet,
):
    """Which place each till sells out of.

    There is no create verb: a profile comes into existence the first time a
    till asks about itself, so a shop never has to enrol its own hardware.
    """

    serializer_class = RegisterProfileSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("sales.view_registerprofile",),
        "retrieve": ("sales.view_registerprofile",),
        "update": ("sales.change_registerprofile",),
        "partial_update": ("sales.change_registerprofile",),
        # Reading your own till's setting is not a management act — every
        # cashier's app asks it on start-up so it can show where it is selling
        # from. Writing it is.
        "me": (),
    }
    queryset = RegisterProfile.objects.select_related("warehouse")
    ordering_fields = ("name", "device_id", "last_seen_at")

    @action(detail=False, methods=["get", "patch"], url_path="me")
    def me(self, request):
        """This device's own profile, created on first ask.

        A till with no device header — an old client, a script — gets the
        shop's default warehouse and no row: there is nothing to remember about
        a device that will not say who it is, and nothing should stop it
        selling.
        """
        from apps.inventory.models import Warehouse
        from apps.sales.registers import device_id_of

        device_id = device_id_of(request)
        if not device_id:
            warehouse = Warehouse.objects.get(pk=Warehouse.default_id())
            return Response(
                {
                    "device_id": "",
                    "warehouse": warehouse.pk,
                    "warehouse_name": warehouse.name,
                    "warehouse_kind": warehouse.kind,
                    "assigned": False,
                }
            )

        profile, _ = RegisterProfile.objects.get_or_create(
            device_id=device_id,
            defaults={"warehouse_id": Warehouse.default_id()},
        )
        if request.method.lower() == "patch":
            if not request.user.has_perm("sales.change_registerprofile"):
                raise PermissionDenied(
                    "تغيير مخزن الصندوق يحتاج صلاحية إدارة الصناديق."
                )
            serializer = self.get_serializer(profile, data=request.data, partial=True)
            serializer.is_valid(raise_exception=True)
            profile = serializer.save()
        else:
            RegisterProfile.objects.filter(pk=profile.pk).update(
                last_seen_at=timezone.now()
            )
        data = self.get_serializer(profile).data
        data["assigned"] = True
        return Response(data)
