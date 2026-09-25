from decimal import Decimal

from django.db.models import (
    Avg,
    Case,
    Count,
    DecimalField,
    ExpressionWrapper,
    F,
    IntegerField,
    Max,
    Min,
    OuterRef,
    Prefetch,
    Q,
    Subquery,
    Sum,
    Value,
    When,
)
from django.db.models.functions import Coalesce
from rest_framework import mixins, parsers, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSerializer, AttachmentSummarySerializer
from apps.catalog.models import Product, ProductVariant, VariantOptionValue
from apps.core.idempotency import run_idempotent_request
from apps.core.pagination import UncountedPageNumberPagination
from apps.core.permissions import HasPointyPermission
from apps.inventory.models import StockLedgerEntry
from apps.inventory.opening_balance import opening_cost_entries
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    Supplier,
    SupplierPayment,
)
from .serializers import (
    ProductCostHistorySerializer,
    ProductOpeningCostSerializer,
    PurchaseAdjustmentHistorySerializer,
    PurchaseDiscountPreviewSerializer,
    PurchaseOrderExchangeSerializer,
    PurchaseOrderRefundSerializer,
    PurchaseReceiptInputSerializer,
    PurchaseOrderReturnSerializer,
    PurchaseOrderListSerializer,
    PurchaseOrderSerializer,
    PurchaseSuggestionResponseSerializer,
    SupplierPaymentSerializer,
    SupplierSerializer,
)
from .services import (
    cancel_purchase_order,
    cancel_supplier_payment,
    clear_purchase_order_applied_discounts,
    create_pos_cash_purchase,
    latest_purchase_line_for_variant,
    latest_purchase_lines_for_variants,
    previous_purchase_line_annotations,
    receive_purchase_order,
    record_purchase_order_audit_event,
    submit_purchase_order,
)


def _product_category_ids(product_id):
    """The category ids a product belongs to, for a category-aware pricing
    suggestion. Resolved server-side from a trusted ``product_id`` (never
    client-sent category ids); returns ``None`` for a blank/invalid id or a
    product with no categories, so the suggestion falls back to the shop markup."""
    if product_id in (None, ""):
        return None
    try:
        pid = int(product_id)
    except (TypeError, ValueError):
        return None
    ids = [
        cid
        for cid in Product.objects.filter(pk=pid).values_list(
            "categories__id", flat=True
        )
        if cid is not None
    ]
    return ids or None


class SupplierViewSet(viewsets.ModelViewSet):
    serializer_class = SupplierSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_supplier",),
        "retrieve": ("purchasing.view_supplier",),
        "purchase_history": ("purchasing.view_supplier",),
        "create": ("purchasing.add_supplier",),
        "update": ("purchasing.change_supplier",),
        "partial_update": ("purchasing.change_supplier",),
        "destroy": ("purchasing.delete_supplier",),
        # The same right as paying one order: money leaving for this supplier.
        "record_payment": ("purchasing.add_supplierpayment",),
    }
    queryset = Supplier.objects.all()
    filterset_fields = ("is_active",)
    search_fields = ("name", "contact_name", "phone", "email", "address")
    ordering_fields = ("name", "created_at", "updated_at")

    def get_required_permissions(self, request):
        # A POS cash purchaser has to say who they bought from, so the narrow
        # purchase permission doubles as read access to the supplier list —
        # without unlocking supplier management.
        if self.action in ("list", "retrieve") and not request.user.has_perm(
            "purchasing.view_supplier"
        ):
            return ("purchasing.add_pos_cash_purchase",)
        return self.permission_map.get(self.action)

    def get_queryset(self):
        # Annotate the purchase totals/counts the serializer needs so a list of
        # suppliers does not run an aggregate + count per row.
        not_cancelled = ~Q(
            purchase_orders__status=PurchaseOrder.Status.CANCELLED,
        )
        return (
            super()
            .get_queryset()
            .annotate(
                purchases_total=Sum("purchase_orders__total", filter=not_cancelled),
                purchases_count=Count("purchase_orders", filter=not_cancelled),
            )
            # Reassert the supplier ordering: aggregating over purchase_orders
            # otherwise leaks that model's default ordering into the GROUP BY,
            # which reorders the list and can split multi-order suppliers into
            # duplicate rows.
            .order_by("name")
        )

    @action(detail=True, methods=["post"], url_path="record-payment")
    def record_payment(self, request, pk=None):
        """Pay this supplier on account.

        Split across everything the shop owes them, oldest first — purchase
        orders and the balances on their account alike — as one ordinary
        supplier payment per document it settles. The only way to pay an
        opening balance, which has no order to pay it from.
        """
        supplier = self.get_object()
        return run_idempotent_request(
            request, lambda: self._record_payment(request, supplier)
        )

    def _record_payment(self, request, supplier):
        from apps.balances.serializers import SupplierAccountPaymentSerializer
        from apps.balances.suppliers import record_supplier_account_payment

        payload = SupplierAccountPaymentSerializer(
            data=request.data, context={"request": request}
        )
        payload.is_valid(raise_exception=True)
        payments = record_supplier_account_payment(
            supplier, created_by=request.user, **payload.validated_data
        )
        fresh = self.get_queryset().get(pk=supplier.pk)
        return Response(
            {
                "supplier": self.get_serializer(fresh).data,
                "payments": SupplierPaymentSerializer(
                    SupplierPayment.objects.select_related(
                        "supplier", "purchase_order", "balance_entry",
                        "created_by", "money_account",
                    ).filter(pk__in=[payment.pk for payment in payments]),
                    many=True,
                    context=self.get_serializer_context(),
                ).data,
            },
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["get"], url_path="purchase-history")
    def purchase_history(self, request, pk=None):
        supplier = self.get_object()
        queryset = PurchaseOrderViewSet.queryset.filter(supplier=supplier).order_by(
            "-created_at", "-id"
        )
        page = self.paginate_queryset(queryset)
        serializer = PurchaseOrderSerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)


class SupplierPaymentViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = SupplierPaymentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_supplierpayment",),
        "retrieve": ("purchasing.view_supplierpayment",),
        "create": ("purchasing.add_supplierpayment",),
        "cancel": ("purchasing.delete_supplierpayment",),
    }
    queryset = SupplierPayment.objects.select_related(
        "supplier",
        "purchase_order",
        "balance_entry",
        "created_by",
        "money_account",
    )
    # Dict form so ``paid_at`` exposes range/day lookups for the Payments hub
    # (money-OUT date window), mirroring PaymentViewSet/OrderViewSet.
    filterset_fields = {
        "supplier": ["exact"],
        "purchase_order": ["exact"],
        "balance_entry": ["exact"],
        "method": ["exact"],
        "paid_at": ["exact", "gte", "lte", "date"],
    }
    search_fields = (
        "supplier__name",
        "purchase_order__order_number",
        "reference",
        "notes",
    )
    ordering_fields = ("paid_at", "created_at", "amount")

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        """Undo a payment. Until now there was no way to: a mistyped payment
        was permanent, and it locked its purchase order shut with it."""
        return run_idempotent_request(request, lambda: self._cancel(request))

    def _cancel(self, request):
        payment = self.get_object()
        cancel_supplier_payment(
            payment,
            reason=str(request.data.get("reason", "")).strip(),
            request=request,
        )
        payment.refresh_from_db()
        serializer = self.get_serializer(payment)
        return Response(serializer.data, status=status.HTTP_200_OK)

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(SupplierPaymentViewSet, self).create(
                request,
                *args,
                **kwargs,
            ),
        )


class PurchaseOrderViewSet(viewsets.ModelViewSet):
    serializer_class = PurchaseOrderSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_purchaseorder",),
        "retrieve": ("purchasing.view_purchaseorder",),
        "last_cost": ("purchasing.view_purchaseorder",),
        "variant_last_cost": ("purchasing.view_purchaseorder",),
        "discount_preview": ("purchasing.add_purchaseorder",),
        # Same code as the discount preview: suggestions are a drafting aid, so
        # the permission that lets you draft is the one that lets you see them.
        "suggestions": ("purchasing.add_purchaseorder",),
        "product_cost_history": ("purchasing.view_purchaseorder",),
        "variant_cost_history": ("purchasing.view_purchaseorder",),
        "product_margin_impact": ("purchasing.view_purchaseorder",),
        "variant_margin_impact": ("purchasing.view_purchaseorder",),
        "product_cost_summary": ("purchasing.view_purchaseorder",),
        "pricing_suggestion": ("purchasing.view_purchaseorder",),
        "outstanding_received_not_paid": ("purchasing.view_purchaseorder",),
        "adjustment_history": ("purchasing.view_purchaseorder",),
        "attachments": ("purchasing.view_purchaseorder", "attachments.view_attachment"),
        "create": ("purchasing.add_purchaseorder",),
        # Deliberately the single narrow code: the flow implies stock-in and the
        # drawer pay-out server-side, so cashiers don't need the broad
        # inventory/receiving permissions the manual lifecycle requires.
        "pos_cash_purchase": ("purchasing.add_pos_cash_purchase",),
        "submit": ("purchasing.edit_draft_purchaseorder",),
        "cancel": ("purchasing.cancel_purchaseorder",),
        "receive": (
            "purchasing.receive_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "return_items": (
            "purchasing.adjust_received_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "refund_items": (
            "purchasing.adjust_received_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "exchange_items": (
            "purchasing.adjust_received_purchaseorder",
            "inventory.add_stockmovement",
        ),
        "update": ("purchasing.edit_draft_purchaseorder",),
        "partial_update": ("purchasing.edit_draft_purchaseorder",),
        "destroy": ("purchasing.delete_purchaseorder",),
    }
    queryset = (
        PurchaseOrder.objects.with_lifecycle_relations()
        .select_related("supplier", "warehouse")
        .prefetch_related(
            # Must come FIRST: Django rejects a Prefetch that carries a queryset for
            # a lookup an earlier `lines__...` string already claimed. Every line
            # renders the previous purchase's cost, which is a query per line unless
            # it rides along as an annotation here.
            Prefetch("lines", queryset=PurchaseLine.objects.annotate(
                **previous_purchase_line_annotations()
            )),
            "lines__variant__product",
            "lines__receipt_lines",
            # PurchaseLine.adjusted_quantity/adjustable_quantity sum this relation;
            # unprefetched they cost 2 aggregate queries per line on every detail
            # read (the return/refund/exchange affordances the details screen shows).
            "lines__adjustment_lines",
            # Every line, receipt line and adjustment line renders its variant's
            # display_name, which falls back to option_values_label -> the
            # option_values M2M. Prefetching it (with its `option` FK, which the
            # label sorts on) turns 1-2 queries per line into 4 for the whole order.
            "lines__variant__option_values__option",
            "landed_cost_entries",
            "receipts__lines__variant__product",
            "receipts__lines__variant__option_values__option",
            "receipts__created_by",
            "adjustments__lines__variant__product",
            "adjustments__lines__variant__option_values__option",
            "adjustments__replacement_lines__variant__product",
            "adjustments__replacement_lines__variant__option_values__option",
            "adjustments__created_by",
            "adjustments__supplier_credit",
            "audit_events__created_by",
            # With the bank each payment left: the details screen names it and
            # draws the bank's mark, which is a query per payment without this.
            Prefetch(
                "supplier_payments",
                queryset=SupplierPayment.objects.select_related("money_account"),
            ),
            "supplier_credits",
            "attachments",
        )
    )
    filterset_fields = {
        "status": ["exact"],
        "supplier": ["exact"],
        "created_at": ["exact", "gte", "lte", "date"],
    }
    search_fields = (
        "order_number",
        "supplier__name",
        "supplier_invoice_number",
        "lines__variant__product__name",
        "lines__variant__sku",
        "lines__variant__barcode",
    )
    ordering_fields = (
        "created_at",
        "updated_at",
        "total",
        "order_number",
        "supplier_invoice_date",
    )

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(
            request,
            lambda: super(PurchaseOrderViewSet, self).create(
                request,
                *args,
                **kwargs,
            ),
        )

    def perform_create(self, serializer):
        serializer.save()
        self._reload_for_response(serializer)

    def perform_update(self, serializer):
        serializer.save()
        self._reload_for_response(serializer)

    def _reload_for_response(self, serializer):
        """Hand the response serializer the order read through the detail
        queryset. The service returns the row it locked, bare: serializing that
        re-aggregates every line's receipt and adjustment totals and re-reads
        its variant, product and option values one query at a time — measured
        at ~20 queries per line on create and PATCH, the bulk of both."""
        serializer.instance = self.get_queryset().get(pk=serializer.instance.pk)

    @action(detail=False, methods=["get"], url_path="last-cost")
    def last_cost(self, request):
        return self._last_cost_response(request)

    @action(detail=False, methods=["get"], url_path="pricing-suggestion")
    def pricing_suggestion(self, request):
        """Suggested sale price for ``?unit_cost=``, using the markup of the
        product's own category when ``?product_id=`` is given (its real pricing
        strategy) and falling back to the shop-wide markup otherwise. Powers the
        purchasing reprice-siblings dialog; a zero/blank/unparseable cost yields a
        null suggested_price."""
        from .pricing import pricing_suggestion as build_pricing_suggestion

        unit_cost = request.query_params.get("unit_cost")
        if unit_cost in (None, ""):
            raise serializers.ValidationError({"unit_cost": "unit_cost is required."})
        category_ids = _product_category_ids(request.query_params.get("product_id"))
        return Response(
            build_pricing_suggestion(unit_cost, category_ids=category_ids)
        )

    def get_required_permissions(self, request):
        if self.action == "attachments" and request.method == "POST":
            return ("purchasing.view_purchaseorder", "attachments.add_attachment")
        # Cost prefill for the POS cash-purchase sheet: the narrow permission is
        # enough to read a product's last purchase cost (but nothing else).
        if self.action in ("last_cost", "variant_last_cost") and not request.user.has_perm(
            "purchasing.view_purchaseorder"
        ):
            return ("purchasing.add_pos_cash_purchase",)
        return self.permission_map.get(self.action)

    # Read-only list-shaped actions: the payables strip endpoint serves the
    # same row summaries as the main list, so both share the lightweight
    # serializer and the trimmed prefetches below.
    _list_shaped_actions = ("list", "outstanding_received_not_paid")

    # The attachments tab needs the order's *identity* and nothing else -- it
    # serializes ``purchase_order.attachments`` with its own queryset -- yet
    # ``get_object()`` runs ``get_queryset()`` regardless, so opening it pulled
    # the whole document tree above (lines, receipts, adjustments, audit
    # events, payments and every variant/option chain under them) and threw
    # every row away.
    _identity_only_actions = ("attachments",)

    def get_serializer_class(self):
        if self.action in self._list_shaped_actions:
            return PurchaseOrderListSerializer
        return PurchaseOrderSerializer

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.action in self._list_shaped_actions:
            # The list rows show only summary + balance + a line COUNT (never the
            # line items themselves — the detail screen re-fetches the full order
            # on open). So drop every heavy tree, including the whole `lines`
            # prefetch that used to ship each order's fully-serialized line items
            # just to render a count (the list payload's bulk), and count lines
            # with a correlated subquery — immune to row inflation from the
            # product/variant line filters below, matching the balance subquery.
            line_count = (
                PurchaseLine.objects.filter(purchase_order=OuterRef("pk"))
                .order_by()
                .values("purchase_order")
                .annotate(count=Count("id"))
                .values("count")[:1]
            )
            queryset = (
                queryset.prefetch_related(None)
                # The three relations the editability gate reads (an order is
                # correctable until money settles against it) — prefetched so
                # the Edit affordance costs three queries a page, not three a row.
                .prefetch_related(
                    "supplier_payments", "supplier_credits", "adjustments"
                )
                .annotate(
                    line_count=Coalesce(
                        Subquery(line_count, output_field=IntegerField()),
                        Value(0),
                        output_field=IntegerField(),
                    )
                )
            )
        elif self.action in self._identity_only_actions:
            queryset = queryset.prefetch_related(None)
        product_id = self.request.query_params.get("product")
        variant_id = self.request.query_params.get("variant")
        if product_id:
            queryset = queryset.filter(lines__variant__product_id=product_id)
        if variant_id:
            queryset = queryset.filter(lines__variant_id=variant_id)
        if product_id or variant_id:
            queryset = queryset.distinct()
        return queryset

    @action(detail=False, methods=["get"], url_path="variant-last-cost")
    def variant_last_cost(self, request):
        return self._last_cost_response(request)

    def _last_cost_response(self, request):
        product_id = request.query_params.get("product")
        variant_id = request.query_params.get("variant")
        if not variant_id:
            raise serializers.ValidationError({"variant": "Variant is required."})

        variant = self._get_variant(variant_id)
        if product_id and str(variant.product_id) != str(product_id):
            raise serializers.ValidationError(
                {"variant": "Variant does not belong to the selected product."}
            )
        line = latest_purchase_line_for_variant(variant.pk)
        return Response(
            {
                "product": variant.product_id,
                "product_id": variant.product_id,
                "variant": variant.pk,
                "variant_id": variant.pk,
                # unit_cost is in the historical line's own purchase unit (162
                # for a carton bought by the carton); base_unit_cost normalises
                # it per base unit so the client can price whichever unit the
                # new line is about to buy in (carton, tray, piece).
                "unit_cost": None if line is None else line.unit_cost,
                "base_unit_cost": None if line is None else line.base_unit_cost,
                "unit": "" if line is None else line.unit,
                "unit_factor": None if line is None else line.unit_factor,
            }
        )

    @action(detail=False, methods=["get"], url_path="suggestions")
    def suggestions(self, request):
        """What this buyer is most likely to add to the draft next.

        ``?supplier=`` is required (habits are per supplier — the same shop buys
        different things from the bakery and the phone wholesaler) and
        ``?variants=`` carries the draft's current lines as the anchors to
        predict from. The whole ranking is served from precomputed tables, so
        this stays a handful of indexed reads however large the history is.

        Returns an empty, ``enabled: false`` payload when the shop has the
        feature switched off, so the client can stop asking without special-casing
        an error.
        """
        from apps.core.models import ShopSettings

        from .suggestions import DEFAULT_LIMIT, cached_suggestions_for_draft
        from .suggestions import suggestions_version as _suggestions_version

        supplier_id = request.query_params.get("supplier")
        if not supplier_id:
            raise serializers.ValidationError({"supplier": "Supplier is required."})
        try:
            supplier_id = int(supplier_id)
        except (TypeError, ValueError):
            raise serializers.ValidationError({"supplier": "Supplier is invalid."})

        if not ShopSettings.load().enable_purchase_suggestions:
            return Response(
                {
                    "supplier": supplier_id,
                    "enabled": False,
                    "version": 0,
                    "items": [],
                    "usual_basket": {
                        "available": False,
                        "line_count": 0,
                        "items": [],
                    },
                }
            )

        anchors = []
        for raw in (request.query_params.get("variants") or "").split(","):
            raw = raw.strip()
            if not raw:
                continue
            try:
                anchors.append(int(raw))
            except (TypeError, ValueError):
                raise serializers.ValidationError(
                    {"variants": "Variants must be a comma-separated list of ids."}
                )

        try:
            limit = int(request.query_params.get("limit") or DEFAULT_LIMIT)
        except (TypeError, ValueError):
            limit = DEFAULT_LIMIT
        limit = max(1, min(limit, 20))

        items, basket = cached_suggestions_for_draft(
            supplier_id=supplier_id,
            anchor_variant_ids=anchors,
            limit=limit,
        )
        return Response(
            PurchaseSuggestionResponseSerializer(
                {
                    "supplier": supplier_id,
                    "enabled": True,
                    "version": _suggestions_version(supplier_id),
                    "items": items,
                    "usual_basket": basket,
                }
            ).data
        )

    @action(detail=False, methods=["post"], url_path="discount-preview")
    def discount_preview(self, request):
        serializer = PurchaseDiscountPreviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return Response(serializer.preview_data)

    @action(detail=False, methods=["get"], url_path="product-cost-history")
    def product_cost_history(self, request):
        return self._cost_history_response()

    @action(detail=False, methods=["get"], url_path="variant-cost-history")
    def variant_cost_history(self, request):
        if not self.request.query_params.get("variant"):
            raise serializers.ValidationError({"variant": "Variant is required."})
        return self._cost_history_response()

    def _cost_history_response(self):
        variant = self._get_optional_variant()
        product = variant.product if variant is not None else self._get_required_product()
        queryset = (
            PurchaseLine.objects.filter(variant__product=product)
            .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
            .select_related("purchase_order__supplier", "variant", "variant__product")
            # This action builds its own queryset rather than going through
            # ``PurchaseOrderViewSet.queryset``, so the option-value prefetch that
            # queryset carries has to be repeated here: every row renders
            # ``variant.display_name``, which falls back to
            # ``option_values_label`` — a query per row — for the unnamed variants
            # a normal shop sells almost exclusively.
            .prefetch_related(
                Prefetch(
                    "variant__option_values",
                    queryset=VariantOptionValue.objects.select_related("option"),
                ),
            )
            .order_by("-created_at", "-id")
        )
        if variant is not None:
            queryset = queryset.filter(variant=variant)
        # A purchase is not the only thing that establishes a cost. Stock the
        # shop already owned when it typed the product in was opened at a cost
        # too, and a history that showed only purchases told a shop that had
        # never raised a PO that it had no cost data — while the till was
        # showing one.
        rows = _MergedCostRows(
            queryset,
            opening_cost_entries(product=product, variant=variant).prefetch_related(
                Prefetch(
                    "variant__option_values",
                    queryset=VariantOptionValue.objects.select_related("option"),
                ),
            ),
        )
        page = self.paginate_queryset(rows)
        data = self._cost_rows_data(page if page is not None else list(rows[:]))
        if page is not None:
            return self.get_paginated_response(data)
        return Response(data)

    def _cost_rows_data(self, rows):
        """Serialize a page that holds both kinds of cost event.

        One serializer per kind rather than one polymorphic one: they share a
        row shape, not a model, and pretending a ledger entry is a purchase
        line is how a null supplier starts reading as a purchase with its
        supplier left blank.
        """
        context = self.get_serializer_context()
        purchase = ProductCostHistorySerializer(context=context)
        opening = ProductOpeningCostSerializer(context=context)
        return [
            (
                opening if isinstance(row, StockLedgerEntry) else purchase
            ).to_representation(row)
            for row in rows
        ]

    @action(detail=False, methods=["get"], url_path="product-margin-impact")
    def product_margin_impact(self, request):
        return self._margin_impact_response()

    @action(detail=False, methods=["get"], url_path="variant-margin-impact")
    def variant_margin_impact(self, request):
        return self._margin_impact_response()

    def _margin_impact_response(self):
        variant = self._get_optional_variant()
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        product = variant.product
        latest_line = latest_purchase_line_for_variant(variant.pk)
        previous_line = (
            None
            if latest_line is None
            else latest_purchase_line_for_variant(variant.pk, before_line=latest_line)
        )
        # The block this feeds sits directly under the cost overview, which
        # already counts opening balances. Leaving it on purchases alone put
        # "12.50" and "not specified" one above the other on the same screen
        # for the same variant.
        latest_line, previous_line = self._two_newest_cost_events(
            variant, latest_line, previous_line
        )
        return Response(
            product_margin_impact_payload(
                product=product,
                variant=variant,
                latest_line=latest_line,
                previous_line=previous_line,
            )
        )

    def _two_newest_cost_events(self, variant, latest_line, previous_line):
        """The last two things that set this variant's cost, of either kind.

        The two newest purchase lines are already in hand, and an opening
        balance can only displace one of them — so merging the openings into
        that pair and taking the top two is the same answer a full merge would
        give, without the full merge.
        """
        candidates = [line for line in (latest_line, previous_line) if line is not None]
        candidates += [
            _OpeningCostLine(entry)
            for entry in opening_cost_entries(variant=variant)
        ]
        if not candidates:
            return None, None
        candidates.sort(key=_cost_row_sort_key, reverse=True)
        return candidates[0], (candidates[1] if len(candidates) > 1 else None)

    @action(detail=False, methods=["get"], url_path="product-cost-summary")
    def product_cost_summary(self, request):
        """Per-variant lowest/highest/last/average cost for a product.

        Powers the "Lowest / Highest / Last cost" metrics on the product &
        variant detail screens and the Change-prices dialog. Two sources feed
        it: received purchase history (excluding cancelled POs) and the opening
        balances a shop typed in when it created the product — a shop that
        never raised a PO still has costs, and this used to report that it had
        none while the till showed one. ``last_cost`` is whichever of the two
        happened most recently, so it can differ from the lowest/highest.
        """
        product = self._get_required_product()
        variants = list(product.variants.all().order_by("-is_default", "name", "id"))
        lines = PurchaseLine.objects.filter(variant__product=product).exclude(
            purchase_order__status=PurchaseOrder.Status.CANCELLED
        )
        # Aggregate per BASE unit: lines are stored per purchase pack (162 for a
        # carton, 5.40 for a tray), so min/max/avg over the raw column would mix
        # denominations and report a carton price as the "cost" next to a
        # per-piece sale price.
        base_cost = Case(
            When(
                unit_factor__gt=0,
                then=ExpressionWrapper(
                    F("effective_unit_cost") / F("unit_factor"),
                    output_field=DecimalField(max_digits=18, decimal_places=6),
                ),
            ),
            default=F("effective_unit_cost"),
            output_field=DecimalField(max_digits=18, decimal_places=6),
        )
        stats_by_variant = {
            row["variant_id"]: row
            for row in lines.values("variant_id").annotate(
                lowest_cost=Min(base_cost),
                highest_cost=Max(base_cost),
                average_cost=Avg(base_cost),
                purchases_count=Count("id"),
            )
        }
        # One query for every variant's newest line rather than one per
        # variant: the field export caught this endpoint at 81 queries for a
        # single product (2026-09-16).
        last_lines = latest_purchase_lines_for_variants(
            variant.pk for variant in variants
        )
        # Opening balances are the other thing that establishes a cost, and
        # for a shop that typed its shelves in rather than buying them through
        # Pointy they are the ONLY thing. One query for the whole product.
        openings_by_variant = {}
        for entry in opening_cost_entries(product=product):
            openings_by_variant.setdefault(entry.variant_id, []).append(entry)
        payload = []
        for variant in variants:
            stats = stats_by_variant.get(variant.pk)
            last_line = last_lines.get(variant.pk)
            openings = openings_by_variant.get(variant.pk, [])
            costs = [
                cost
                for cost in (
                    stats["lowest_cost"] if stats else None,
                    stats["highest_cost"] if stats else None,
                    *(entry.valuation_rate for entry in openings),
                )
                if cost is not None
            ]
            # Averaged over events, not over sources: a variant bought three
            # times and opened once is a mean of four costs, so folding the
            # purchase mean back in has to carry the count it was taken over.
            purchases_count = stats["purchases_count"] if stats else 0
            total_count = purchases_count + len(openings)
            average = None
            if total_count:
                total = sum(
                    (entry.valuation_rate for entry in openings), Decimal("0")
                )
                if stats and purchases_count:
                    total += Decimal(stats["average_cost"]) * purchases_count
                average = total / total_count
            # ``last_cost`` is the most RECENT cost, whichever kind of event
            # set it — an opening balance typed today outranks a purchase from
            # last year, and vice versa.
            last_cost = (
                None if last_line is None else last_line.effective_base_unit_cost
            )
            newest_opening = max(
                openings, key=lambda entry: entry.posting_at, default=None
            )
            if newest_opening is not None and (
                last_line is None
                or newest_opening.posting_at >= last_line.created_at
            ):
                last_cost = _money_2dp(newest_opening.valuation_rate)
            payload.append(
                {
                    "product": product.pk,
                    "variant": variant.pk,
                    "variant_name": variant.display_name,
                    "unit_price": variant.unit_price,
                    "lowest_cost": _money_2dp(min(costs)) if costs else None,
                    "highest_cost": _money_2dp(max(costs)) if costs else None,
                    "average_cost": _money_2dp(average),
                    "last_cost": last_cost,
                    "purchases_count": purchases_count,
                    # Openings are counted separately: "bought 3 times" and
                    # "opened once" are different sentences, and a client that
                    # says "3 purchases" must not start saying 4.
                    "openings_count": len(openings),
                }
            )
        return Response(payload)

    @action(detail=False, methods=["get"], url_path="outstanding-received-not-paid")
    def outstanding_received_not_paid(self, request):
        """Received orders the shop still owes money on, most urgent first.

        An order is outstanding when its billable total still exceeds
        everything paid against it. The billable total nets off
        ``cancelled_total`` — goods a receipt closed as never-arriving — so an
        order settled in full for what actually turned up stops being listed
        instead of sitting on the payables screen forever. ``paid_total`` and
        ``credit_applied_total`` together cover every payment method, so one
        sum over live ``SupplierPayment`` rows is the whole of "paid".

        Written as a *set difference* rather than a per-order comparison.
        Asking each received order for the sum of its own payments is a
        correlated subquery the database must run once per row, and nothing
        about it can be indexed: the 2026-09-16 field export measured 581ms of
        database time here, and the walk grows with every delivery the shop
        has ever taken in. But an order with no payments at all — most of them —
        is outstanding purely by its own columns, and the orders that *do* have
        payments are reachable in one grouped pass over the payments table,
        which is far smaller. So: every received order that is billable at all,
        minus the ones whose payments already cover them.
        """
        # Orders whose live payments already cover the billable total. One
        # aggregate over the payments table, joined to its order for the
        # comparison — it visits payments, not every order ever received.
        settled = (
            SupplierPayment.objects.live()
            .filter(purchase_order__isnull=False)
            .values("purchase_order")
            .annotate(paid=Sum("amount"))
            .filter(
                paid__gte=F("purchase_order__total")
                - F("purchase_order__cancelled_total")
            )
            .values("purchase_order")
        )
        # Most urgent first: dated orders by earliest due date, undated ones
        # last, most recently received breaking ties.
        ordering = (
            F("due_date").asc(nulls_last=True),
            Coalesce("received_at", "created_at").desc(),
            "-id",
        )

        def outstanding(queryset):
            return (
                queryset.filter(status=PurchaseOrder.Status.RECEIVED)
                .filter(total__gt=F("cancelled_total"))
                .exclude(pk__in=settled)
                .order_by(*ordering)
            )

        # Choose the page over the order table alone, then hydrate only the
        # rows that made it. Filtering and sorting on the viewset's own
        # queryset made the database build the joined supplier, warehouse and
        # lifecycle-user columns for every candidate (about 5KB a row over
        # 11,700 rows at the field shop) and then discard all but fifty.
        candidates = outstanding(self.get_queryset().select_related(None))
        paginator = UncountedPageNumberPagination()
        page_ids = paginator.paginate_queryset(
            candidates.values_list("pk", flat=True),
            request,
            view=self,
        )
        if page_ids is None:
            serializer = self.get_serializer(
                outstanding(self.get_queryset()), many=True
            )
            return Response(serializer.data)
        # ``balance_due``/``payment_status`` are Python properties over the
        # prefetched payment, credit and adjustment rows, so the page needs the
        # viewset's prefetches — and only for these fifty.
        page = outstanding(self.get_queryset().filter(pk__in=list(page_ids)))
        serializer = self.get_serializer(page, many=True)
        return paginator.get_paginated_response(serializer.data)

    @action(detail=False, methods=["get"], url_path="adjustment-history")
    def adjustment_history(self, request):
        adjustment_type = request.query_params.get("adjustment_type")
        queryset = (
            PurchaseOrderAdjustmentLine.objects.select_related(
                "adjustment__purchase_order__supplier",
                "purchase_line",
                "variant",
                "variant__product",
            )
            # Same as ``_cost_history_response``: ``variant_name`` is
            # ``variant.display_name``, whose ``option_values_label`` fallback
            # queries once per row unless the option values are prefetched.
            .prefetch_related(
                Prefetch(
                    "variant__option_values",
                    queryset=VariantOptionValue.objects.select_related("option"),
                ),
            )
            .filter(
                adjustment__adjustment_type__in=(
                    PurchaseOrderAdjustment.AdjustmentType.RETURN,
                    PurchaseOrderAdjustment.AdjustmentType.REFUND,
                )
            )
            .order_by("-adjustment__created_at", "-adjustment_id", "-id")
        )
        if adjustment_type:
            if adjustment_type not in (
                PurchaseOrderAdjustment.AdjustmentType.RETURN,
                PurchaseOrderAdjustment.AdjustmentType.REFUND,
            ):
                raise serializers.ValidationError({"adjustment_type": "Use return or refund."})
            queryset = queryset.filter(adjustment__adjustment_type=adjustment_type)
        supplier_id = request.query_params.get("supplier")
        if supplier_id:
            queryset = queryset.filter(
                adjustment__purchase_order__supplier_id=supplier_id,
            )
        variant_id = request.query_params.get("variant")
        if variant_id:
            variant = self._get_variant(variant_id)
            product_id = request.query_params.get("product")
            if product_id and str(variant.product_id) != str(product_id):
                raise serializers.ValidationError(
                    {"variant": "Variant does not belong to the selected product."}
                )
            queryset = queryset.filter(variant=variant)
        else:
            product_id = request.query_params.get("product")
            if product_id:
                queryset = queryset.filter(variant__product_id=product_id)

        page = self.paginate_queryset(queryset)
        serializer = PurchaseAdjustmentHistorySerializer(
            page if page is not None else queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)

    @action(
        detail=True,
        methods=["get", "post"],
        url_path="attachments",
        parser_classes=[parsers.MultiPartParser, parsers.FormParser, parsers.JSONParser],
    )
    def attachments(self, request, pk=None):
        purchase_order = self.get_object()
        if request.method.lower() == "post":
            return self._create_attachment_for_purchase_order(request, purchase_order)

        queryset = purchase_order.attachments.active().select_related(
            "owner_content_type",
            "storage_volume",
            "created_by",
        )
        serializer = AttachmentSummarySerializer(
            queryset,
            many=True,
            context=self.get_serializer_context(),
        )
        return Response(serializer.data)

    def _create_attachment_for_purchase_order(self, request, purchase_order):
        data = request.data.copy()
        data.setdefault("role", Attachment.Role.SUPPLIER_INVOICE_SCAN)
        serializer = AttachmentSerializer(
            data=data,
            context={**self.get_serializer_context(), "owner": purchase_order},
        )
        serializer.is_valid(raise_exception=True)
        attachment = serializer.save()
        return Response(
            AttachmentSummarySerializer(
                attachment,
                context=self.get_serializer_context(),
            ).data,
            status=status.HTTP_201_CREATED,
        )

    def _get_required_product(self):
        product_id = self.request.query_params.get("product")
        if not product_id:
            raise serializers.ValidationError({"product": "Product is required."})
        return self._get_product(product_id)

    def _get_product(self, product_id):
        try:
            return Product.objects.get(pk=product_id)
        except (Product.DoesNotExist, ValueError):
            raise serializers.ValidationError({"product": "Product does not exist."})

    def _get_variant(self, variant_id):
        try:
            return ProductVariant.objects.select_related("product").get(pk=variant_id)
        except (ProductVariant.DoesNotExist, ValueError):
            raise serializers.ValidationError({"variant": "Variant does not exist."})

    def _get_optional_variant(self):
        variant_id = self.request.query_params.get("variant")
        if not variant_id:
            return None
        variant = self._get_variant(variant_id)
        product_id = self.request.query_params.get("product")
        if product_id and str(variant.product_id) != str(product_id):
            raise serializers.ValidationError(
                {"variant": "Variant does not belong to the selected product."}
            )
        return variant

    def _detail_response(self, purchase_order, *, status_code=status.HTTP_200_OK):
        """Serialize a just-mutated order through the prefetch-rich queryset.

        The lifecycle actions below hand back an order they loaded bare — the
        service layer locks it with ``select_for_update().get(...)``, and
        ``refresh_from_db()`` drops any prefetch cache — so the detail
        serializer then re-queried every nested line, receipt line, adjustment
        and variant one row at a time. Re-reading the order through the
        class-level queryset pays the prefetch tree once instead. Measured on a
        20-line receive: 495 -> 41 queries for the response payload.

        Deliberately ``self.queryset`` and not ``get_queryset()``: the latter
        layers the list-only ``?product=``/``?variant=`` filters, which would
        filter the just-mutated order out of its own response.
        """
        order = self.queryset.get(pk=purchase_order.pk)
        return Response(self.get_serializer(order).data, status=status_code)

    @action(detail=False, methods=["post"], url_path="pos-cash-purchase")
    def pos_cash_purchase(self, request):
        """Drawer purchase from the sell screen: the posted PO is created,
        received into stock, and paid in full in cash against the caller's open
        register session in one atomic step. Body = the normal PO create
        payload (supplier + lines)."""
        return run_idempotent_request(
            request,
            lambda: self._pos_cash_purchase(request),
        )

    def _pos_cash_purchase(self, request):
        # Tells the serializer which cost rules apply: this path blocks an
        # implausible cost outright instead of offering a confirmation the
        # cashier could not act on anyway.
        serializer = self.get_serializer(data=request.data)
        serializer.context["pos_cash_purchase"] = True
        serializer.is_valid(raise_exception=True)
        purchase_order = create_pos_cash_purchase(
            request=request,
            validated_data=serializer.validated_data,
        )
        return self._detail_response(
            purchase_order,
            status_code=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def submit(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._submit(request),
        )

    def _submit(self, request):
        purchase_order = submit_purchase_order(self.get_object(), request=request)
        return self._detail_response(purchase_order)

    @action(detail=True, methods=["post"])
    def receive(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._receive(request),
        )

    def _receive(self, request):
        lines_data = None
        notes = ""
        # One load, not one per use: get_object() re-runs the whole detail
        # prefetch tree (and the object-permission check) on every call, and a
        # partial receipt used to call it twice.
        purchase_order = self.get_object()
        if request.data:
            serializer = PurchaseReceiptInputSerializer(
                data=request.data,
                context={"purchase_order": purchase_order},
            )
            serializer.is_valid(raise_exception=True)
            lines_data = serializer.validated_data["validated_lines"]
            notes = serializer.validated_data.get("notes", "")
        purchase_order = receive_purchase_order(
            purchase_order,
            request=request,
            lines_data=lines_data,
            notes=notes,
        )
        return self._detail_response(purchase_order)

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        return run_idempotent_request(
            request,
            lambda: self._cancel(request),
        )

    def _cancel(self, request):
        purchase_order = cancel_purchase_order(self.get_object(), request=request)
        return self._detail_response(purchase_order)

    @action(detail=True, methods=["post"], url_path="return-items")
    def return_items(self, request, pk=None):
        return self._adjust_items(request, PurchaseOrderReturnSerializer)

    @action(detail=True, methods=["post"], url_path="refund-items")
    def refund_items(self, request, pk=None):
        return self._adjust_items(request, PurchaseOrderRefundSerializer)

    @action(detail=True, methods=["post"], url_path="exchange-items")
    def exchange_items(self, request, pk=None):
        return self._adjust_items(request, PurchaseOrderExchangeSerializer)

    def _adjust_items(self, request, serializer_class):
        return run_idempotent_request(
            request,
            lambda: self._adjust_items_once(request, serializer_class),
        )

    def _adjust_items_once(self, request, serializer_class):
        purchase_order = self.get_object()
        serializer = serializer_class(
            data=request.data,
            context={"purchase_order": purchase_order, "request": request},
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return self._detail_response(purchase_order)

    def destroy(self, request, *args, **kwargs):
        purchase_order = self.get_object()
        if purchase_order.status != PurchaseOrder.Status.DRAFT:
            raise serializers.ValidationError(
                {"detail": "Only draft purchase orders can be deleted."}
            )
        record_purchase_order_audit_event(
            purchase_order,
            "deleted",
            request=request,
        )
        clear_purchase_order_applied_discounts(purchase_order)
        purchase_order.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


def money_string(value):
    return None if value is None else str(value.quantize(Decimal("0.01")))


def _money_2dp(value):
    """Quantize a (possibly high-precision) per-base-unit cost to money — the
    SQL divide by ``unit_factor`` yields 6dp intermediates."""
    return None if value is None else Decimal(value).quantize(Decimal("0.01"))


class _OpeningCostLine:
    """An opening balance in the shape the margin maths reads a purchase line.

    Never saved and never a ``PurchaseLine``: the margin block asks a cost
    event two questions — what it cost per base unit, and which row it was —
    and an opening balance answers the first while having no answer to the
    second. ``pk`` is None rather than borrowed from the ledger entry, because
    a client following ``latest_purchase_line`` to a purchase order must not
    be handed an id that points at something else entirely.
    """

    pk = None

    def __init__(self, entry):
        self.entry = entry
        # Named ``created_at`` so it sorts through the same key a purchase
        # line does.
        self.created_at = entry.posting_at
        self.base_unit_cost = _money_2dp(entry.valuation_rate)
        self.effective_base_unit_cost = self.base_unit_cost


def _cost_row_sort_key(row):
    """Newest first, deterministically, across two tables.

    The second element breaks a tie between a purchase line and an opening
    balance stamped in the same instant — without it the two could swap places
    between one page request and the next, which on an offset-paginated list
    means a row served twice and another never served at all.
    """
    if isinstance(row, StockLedgerEntry):
        return (row.posting_at, 1, row.pk)
    if isinstance(row, _OpeningCostLine):
        return (row.created_at, 1, row.entry.pk)
    return (row.created_at, 0, row.pk)


class _MergedCostRows:
    """Purchase lines and opening balances as one newest-first sequence.

    Paginated by Django's own ``Paginator``, which asks a sequence for its
    length and then for one slice — both answerable without materialising
    either source. The length is two COUNTs. A slice fetches at most ``stop``
    purchase lines (exactly what offset pagination was already costing) and
    merges them against the opening entries — a handful, since a variant is
    opened when its product is created and not again.

    Taking ``stop`` lines is enough because both inputs are already sorted: a
    purchase line lying beyond index ``stop`` of its own list cannot reach the
    first ``stop`` places of the merged one, since every line ahead of it in
    that list is ahead of it in the merge too.
    """

    def __init__(self, purchase_lines, openings):
        self._lines = purchase_lines
        # The cheap side of the merge, read whole: one row per variant that
        # was opened, against a purchase history that can run to thousands.
        self._openings = sorted(openings, key=_cost_row_sort_key, reverse=True)

    def count(self):
        return self._lines.count() + len(self._openings)

    def __len__(self):
        return self.count()

    def __getitem__(self, window):
        stop = window.stop
        lines = self._lines[:stop] if stop is not None else self._lines
        merged = sorted(
            [*lines, *self._openings], key=_cost_row_sort_key, reverse=True
        )
        return merged[window]


def margin_amount(variant, line):
    if line is None:
        return None
    # unit_price is per base unit; the line's cost must be too, or a carton
    # purchase reads as selling every piece at a giant loss.
    return (variant.unit_price - line.effective_base_unit_cost).quantize(
        Decimal("0.01")
    )


def margin_percent(variant, line):
    amount = margin_amount(variant, line)
    if amount is None or variant.unit_price == Decimal("0.00"):
        return None
    return (amount / variant.unit_price * Decimal("100")).quantize(Decimal("0.01"))


def decimal_delta(latest, previous):
    if latest is None or previous is None:
        return None
    return (latest - previous).quantize(Decimal("0.01"))


def product_margin_impact_payload(*, product, variant, latest_line, previous_line):
    latest_margin_amount = margin_amount(variant, latest_line)
    previous_margin_amount = margin_amount(variant, previous_line)
    latest_margin_percent = margin_percent(variant, latest_line)
    previous_margin_percent = margin_percent(variant, previous_line)
    # Everything in this payload sits next to the per-base unit_price, and the
    # latest/previous lines may have been bought in different packs (a carton
    # this week, loose pieces last week) — per-base is the only denomination
    # their costs and deltas are comparable in.
    latest_effective_cost = (
        None if latest_line is None else latest_line.effective_base_unit_cost
    )
    previous_effective_cost = (
        None if previous_line is None else previous_line.effective_base_unit_cost
    )
    latest_unit_cost = None if latest_line is None else latest_line.base_unit_cost
    previous_unit_cost = None if previous_line is None else previous_line.base_unit_cost
    return {
        "product": product.pk,
        "variant": variant.pk,
        "product_name": product.name,
        "variant_name": variant.display_name,
        "unit_price": money_string(variant.unit_price),
        "latest_purchase_line": None if latest_line is None else latest_line.pk,
        "latest_unit_cost": money_string(latest_unit_cost),
        "effective_unit_cost": money_string(latest_effective_cost),
        "latest_effective_unit_cost": money_string(latest_effective_cost),
        "latest_margin_amount": money_string(latest_margin_amount),
        "latest_margin_percent": money_string(latest_margin_percent),
        "previous_purchase_line": None if previous_line is None else previous_line.pk,
        "previous_unit_cost": money_string(previous_unit_cost),
        "previous_effective_unit_cost": money_string(previous_effective_cost),
        "previous_margin_amount": money_string(previous_margin_amount),
        "previous_margin_percent": money_string(previous_margin_percent),
        "unit_cost_delta": money_string(decimal_delta(latest_unit_cost, previous_unit_cost)),
        "effective_unit_cost_delta": money_string(
            decimal_delta(latest_effective_cost, previous_effective_cost)
        ),
        "margin_amount_delta": money_string(
            decimal_delta(latest_margin_amount, previous_margin_amount)
        ),
        "margin_percent_delta": money_string(
            decimal_delta(latest_margin_percent, previous_margin_percent)
        ),
    }


