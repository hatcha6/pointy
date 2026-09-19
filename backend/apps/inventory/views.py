from decimal import Decimal

import django_filters
from django.db import IntegrityError, transaction
from django.db.models import Count, F, Prefetch, Q
from django.utils import timezone
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.catalog.models import ProductVariant
from apps.catalog.services import (
    category_ids_with_descendants,
    variant_detail_queryset,
)
from apps.core.idempotency import run_idempotent_request
from apps.documents import services as document_services
from apps.documents.statuses import DocumentStatus
from apps.core.models import ShopSettings
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility
from .models import (
    StockCount,
    StockCountLine,
    StockItem,
    StockLedgerEntry,
    StockMovement,
    StockTransfer,
    StockTransferLine,
    StockUnit,
    Warehouse,
)
from . import stock_count_tracking
from . import transfers as transfer_services
from .serializers import (
    StockItemSerializer,
    StockMovementSerializer,
    StockTransferReceiptLineInputSerializer,
    StockTransferSerializer,
    WarehouseSerializer,
)
from .services import (
    allocate_adjustment,
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_count_needs_review,
    stock_snapshot,
)
from .valuation_service import post_movement_valuations
from .stock_count_serializers import (
    StockCountDetailSerializer,
    StockCountLineInputSerializer,
    StockCountLineSerializer,
    StockCountReconciliationLineSerializer,
    StockCountSerializer,
    StockCountStartSerializer,
)


def _selling_warehouse_id(request):
    """Where the till making this request actually keeps its stock.

    Imported inside the call for the same reason ``tracked_views`` does it:
    ``apps.sales`` imports this app, and a module-level import the other way
    would close the circle.
    """
    from apps.sales.registers import selling_warehouse_id

    return selling_warehouse_id(request)


class StockItemFilter(django_filters.FilterSet):
    product = django_filters.NumberFilter(field_name="variant__product_id")

    class Meta:
        model = StockItem
        fields = ("product", "variant", "warehouse")


class StockItemViewSet(viewsets.ModelViewSet):
    serializer_class = StockItemSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockitem",),
        "retrieve": ("inventory.view_stockitem",),
        "create": ("inventory.add_stockitem",),
        "update": ("inventory.change_stockitem",),
        "partial_update": ("inventory.change_stockitem",),
        "destroy": ("inventory.delete_stockitem",),
    }
    queryset = StockItem.objects.select_related(
        "variant",
        # display_name/full_name read the parent product's name.
        "variant__product",
        # Every row names the place it is in; without this that is a query per
        # row the moment a shop opens a second warehouse.
        "warehouse",
    ).prefetch_related(
        # display_name falls back to option_values_label, which queries
        # option_values once per variant unless it is prefetched.
        "variant__option_values__option",
    )
    filterset_class = StockItemFilter
    search_fields = (
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
    )
    ordering_fields = ("quantity_on_hand", "updated_at")


class StockMovementFilter(django_filters.FilterSet):
    product = django_filters.NumberFilter(field_name="variant__product_id")

    class Meta:
        model = StockMovement
        fields = ("product", "variant", "movement_type")


class StockMovementViewSet(
    mixins.CreateModelMixin,
    mixins.RetrieveModelMixin,
    mixins.ListModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = StockMovementSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockmovement",),
        "retrieve": ("inventory.view_stockmovement",),
        "create": ("inventory.add_stockmovement",),
    }
    queryset = StockMovement.objects.select_related(
        "variant",
        # display_name/full_name read the parent product's name.
        "variant__product",
        "stock_item",
        "created_by",
    ).prefetch_related(
        # display_name falls back to option_values_label, which queries
        # option_values once per variant unless it is prefetched.
        "variant__option_values__option",
    )
    filterset_class = StockMovementFilter
    search_fields = (
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
        "note",
    )
    ordering_fields = ("created_at", "quantity", "movement_type")

    def perform_create(self, serializer):
        variant = serializer.validated_data["variant"]
        quantity = serializer.validated_data["quantity"]
        movement_type = serializer.validated_data["movement_type"]

        payload = self.request.data or {}
        with transaction.atomic():
            # ``get_or_create(variant=...)`` was a ``MultipleObjectsReturned``
            # waiting for the second warehouse: a variant has one stock row per
            # place, and this endpoint asked for "the" one. The register's own
            # location is the answer, the same one every other write uses.
            stock_item = lock_stock_item(
                variant=variant, warehouse=_selling_warehouse_id(self.request)
            )
            before = {
                "on_hand": stock_item.quantity_on_hand,
                "committed": stock_item.quantity_committed,
                "expected": stock_item.quantity_expected,
            }
            after = self._apply_movement(stock_item, movement_type, quantity)
            stock_item.save(
                update_fields=[
                    "quantity_on_hand",
                    "quantity_committed",
                    "quantity_expected",
                    "updated_at",
                ],
            )
            # Which identified articles this adjustment moved. A shelf that
            # changes by hand is still a shelf, so a tracked product is named
            # here or the adjustment is refused — and the plan travels onto the
            # movement, because applying it without carrying it is the same
            # drift by a longer road.
            plan = allocate_adjustment(
                variant=variant,
                warehouse=stock_item.warehouse_id,
                delta=after["on_hand"] - before["on_hand"],
                units=payload.get("units"),
                batches=payload.get("batches"),
                status=(
                    StockUnit.Status.DAMAGED
                    if movement_type == StockMovement.Type.DAMAGED
                    else StockUnit.Status.WRITTEN_OFF
                ),
                placeholder_key=f"MV-{variant.pk}",
                what="هذه التسوية",
            )
            movement = serializer.save(
                stock_item=stock_item,
                variant=variant,
                created_by=self.request.user,
                on_hand_before=before["on_hand"],
                on_hand_after=after["on_hand"],
                committed_before=before["committed"],
                committed_after=after["committed"],
                expected_before=before["expected"],
                expected_after=after["expected"],
            )
            # A manual adjustment never reached the ledger at all: the shelf
            # moved, the bin did not, and the shop's stock value quietly
            # stopped matching its stock. It is a voucher like any other.
            movement.tracked_plan = plan
            post_movement_valuations(
                [movement],
                voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
                voucher_id=movement.pk,
                warehouse=stock_item.warehouse_id,
            )
            record_domain_event(
                name="inventory.manual_movement.created",
                event_type=AnalyticsEvent.EventType.AUDIT,
                severity=(
                    AnalyticsEvent.Severity.WARNING
                    if movement_type
                    in (StockMovement.Type.DECREASE, StockMovement.Type.DAMAGED)
                    else AnalyticsEvent.Severity.INFO
                ),
                user=self.request.user,
                entity_type="stock_movement",
                entity_id=movement.pk,
                attributes={
                    "variant_id": variant.pk,
                    "product_id": variant.product_id,
                    "movement_type": movement_type,
                    "note_present": bool(movement.note),
                },
                metrics={
                    "quantity": quantity,
                    "on_hand_before": before["on_hand"],
                    "on_hand_after": after["on_hand"],
                    "expected_before": before["expected"],
                    "expected_after": after["expected"],
                },
            )

    def _apply_movement(self, stock_item, movement_type, quantity):
        if movement_type == StockMovement.Type.INCREASE:
            stock_item.quantity_on_hand += quantity
        elif movement_type == StockMovement.Type.EXPECTED:
            stock_item.quantity_expected += quantity
        elif movement_type == StockMovement.Type.RECEIVE_EXPECTED:
            stock_item.quantity_on_hand += quantity
            stock_item.quantity_expected -= quantity
        elif movement_type == StockMovement.Type.RECEIVE_DAMAGED:
            stock_item.quantity_expected -= quantity
        elif movement_type == StockMovement.Type.CANCEL_EXPECTED:
            stock_item.quantity_expected -= quantity
        elif movement_type in (
            StockMovement.Type.DECREASE,
            StockMovement.Type.DAMAGED,
        ):
            stock_item.quantity_on_hand -= quantity

        if stock_item.quantity_on_hand < 0:
            raise serializers.ValidationError(
                {"quantity": "Stock on hand cannot become negative."}
            )
        if stock_item.quantity_expected < 0:
            raise serializers.ValidationError(
                {"quantity": "Expected stock cannot become negative."}
            )

        return {
            "on_hand": stock_item.quantity_on_hand,
            "committed": stock_item.quantity_committed,
            "expected": stock_item.quantity_expected,
        }


def stock_count_owner_key(request):
    if request.user.is_authenticated:
        return f"user:{request.user.pk}"
    return "anonymous"


def stock_count_owner(request):
    if request.user.is_authenticated:
        return request.user
    return None


class StockCountFilter(django_filters.FilterSet):
    class Meta:
        model = StockCount
        fields = ("status", "scope")


class StockCountViewSet(
    mixins.RetrieveModelMixin,
    mixins.ListModelMixin,
    viewsets.GenericViewSet,
):
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockcount",),
        "retrieve": ("inventory.view_stockcount",),
        "current": ("inventory.view_stockcount",),
        "reconciliation": ("inventory.view_stockcount",),
        "start": ("inventory.add_stockcount",),
        "count": ("inventory.add_stockcount", "inventory.change_stockcount"),
        "scan": ("inventory.add_stockcount", "inventory.change_stockcount"),
        "scan_reconciliation": ("inventory.view_stockcount",),
        "cancel": ("inventory.change_stockcount",),
        "apply": ("inventory.apply_stockcount",),
    }
    queryset = StockCount.objects.select_related(
        "owner",
        "applied_by",
        "category",
        # Every row names the place it counted; unjoined that is a query per row
        # on a list whose whole point is being read at a glance.
        "warehouse",
    )
    filterset_class = StockCountFilter
    search_fields = ("note", "category__name")
    ordering_fields = ("created_at", "applied_at", "status")

    def get_serializer_class(self):
        if self.action in ("retrieve", "start", "apply", "cancel", "current"):
            return StockCountDetailSerializer
        return StockCountSerializer

    def get_queryset(self):
        # Both counts aggregate the SAME reverse relation, so they share one
        # join and cannot fan out into a cross product. variance_line_count was
        # left un-annotated, which made the serializer fall back to a COUNT(*)
        # per row of the list.
        queryset = super().get_queryset().annotate(
            counted_line_count=Count("lines", distinct=True),
            variance_line_count=Count(
                "lines",
                filter=~Q(lines__counted_quantity=F("lines__expected_quantity")),
                distinct=True,
            ),
        )
        # Anyone who can apply counts (managers, supervisors, storekeepers) must
        # be able to see every count to review/apply it; reporting roles get the
        # same shop-wide view. Floor staff stay scoped to their own counts. The
        # blind "current"/"start" lookups filter by owner_key directly, so this
        # never leaks another counter's in-progress count into the count loop.
        user = self.request.user
        if user_has_full_visibility(user) or user.has_perm("inventory.apply_stockcount"):
            return queryset
        return queryset.filter(owner_key=stock_count_owner_key(self.request))

    # -- counting set ---------------------------------------------------------

    def _counting_variants_queryset(self, stock_count):
        """Active, stock-tracked variants in scope (service/prepared excluded)."""
        queryset = ProductVariant.objects.filter(
            is_active=True,
            product__is_active=True,
            product__archived_at__isnull=True,
            product__is_service=False,
            product__is_prepared=False,
        )
        if stock_count.scope == StockCount.Scope.CATEGORY and stock_count.category_id:
            category_ids = category_ids_with_descendants([stock_count.category_id])
            queryset = queryset.filter(
                product__categories__id__in=category_ids,
            ).distinct()
        return queryset

    def _detail_data(self, stock_count):
        return StockCountDetailSerializer(
            stock_count,
            context=self.get_serializer_context(),
        ).data

    # -- actions --------------------------------------------------------------

    @action(detail=False, methods=["get"])
    def current(self, request):
        session = (
            self.get_queryset()
            .filter(
                owner_key=stock_count_owner_key(request),
                status=StockCount.Status.IN_PROGRESS,
            )
            .first()
        )
        if session is None:
            return Response(status=status.HTTP_204_NO_CONTENT)
        return Response(self._detail_data(session))

    @action(detail=False, methods=["post"])
    def start(self, request):
        return run_idempotent_request(request, lambda: self._start(request))

    def _start(self, request):
        serializer = StockCountStartSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        owner_key = stock_count_owner_key(request)

        try:
            with transaction.atomic():
                session = (
                    StockCount.objects.select_for_update()
                    .filter(
                        owner_key=owner_key,
                        status=StockCount.Status.IN_PROGRESS,
                    )
                    .first()
                )
                reused = session is not None
                if session is None:
                    session = StockCount.objects.create(
                        owner=stock_count_owner(request),
                        owner_key=owner_key,
                        scope=serializer.validated_data["scope"],
                        category=serializer.validated_data.get("category"),
                        note=serializer.validated_data.get("note", ""),
                    )
                    session.expected_line_count = self._counting_variants_queryset(
                        session
                    ).count()
                    session.save(
                        update_fields=["expected_line_count", "updated_at"]
                    )
        except IntegrityError:
            session = StockCount.objects.get(
                owner_key=owner_key,
                status=StockCount.Status.IN_PROGRESS,
            )
            reused = True

        record_domain_event(
            name="inventory.stock_count.started",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="stock_count",
            entity_id=session.pk,
            attributes={
                "owner_key": owner_key,
                "scope": session.scope,
                "category_id": session.category_id,
                "existing_session_reused": reused,
            },
            metrics={"expected_line_count": session.expected_line_count},
        )
        return Response(
            self._detail_data(session),
            status=status.HTTP_200_OK if reused else status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def count(self, request, pk=None):
        input_serializer = StockCountLineInputSerializer(data=request.data)
        input_serializer.is_valid(raise_exception=True)
        variant = input_serializer.validated_data["variant"]
        counted_quantity = input_serializer.validated_data["counted_quantity"]
        mode = input_serializer.validated_data["mode"]
        batch = input_serializer.validated_data.get("batch")

        stock_count = self.get_object()
        if stock_count.status != StockCount.Status.IN_PROGRESS:
            return Response(
                {"detail": "Stock count is not in progress."},
                status=status.HTTP_409_CONFLICT,
            )
        product = variant.product
        if product.is_service or product.is_prepared:
            return Response(
                {"variant": "This product is not stock-tracked."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if stock_count_tracking.counts_by_scan(variant):
            # Counting a *number* of serialized articles is meaningless: two
            # handsets of one model are not interchangeable, and the count that
            # matters is which ones are on the shelf.
            return Response(
                {
                    "variant": (
                        "هذا الصنف مسلسل — امسح معرّف كل وحدة موجودة "
                        "بدل إدخال كمية."
                    ),
                    "tracking_mode": variant.product.tracking_mode,
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        if batch is not None and batch.variant_id != variant.pk:
            return Response(
                {"batch": "هذه الدفعة ليست من هذا الصنف."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if batch is None and stock_count_tracking.counts_by_lot(variant):
            return Response(
                {
                    "batch": (
                        "هذا الصنف مُدار بالدفعات — اختر الدفعة التي تعدّها."
                    )
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        shop_settings = ShopSettings.load()
        with transaction.atomic():
            stock_item = lock_stock_item(
                variant=variant, warehouse=stock_count.warehouse_id
            )
            existing = (
                StockCountLine.objects.select_for_update()
                .filter(stock_count=stock_count, variant=variant, batch=batch)
                .first()
            )
            if batch is not None:
                line_stub = StockCountLine(batch=batch)
                expected = stock_count_tracking.lot_line_expected(
                    stock_count, line_stub
                )
            else:
                expected = stock_item.quantity_on_hand
            if existing is not None and mode == "add":
                new_counted = existing.counted_quantity + counted_quantity
            else:
                new_counted = counted_quantity
            needs_review = stock_count_needs_review(
                expected=expected,
                counted=new_counted,
                min_units=shop_settings.stock_count_variance_min_units,
                percent=shop_settings.stock_count_variance_percent,
            )
            line, _ = StockCountLine.objects.update_or_create(
                stock_count=stock_count,
                variant=variant,
                batch=batch,
                defaults={
                    "counted_quantity": new_counted,
                    "expected_quantity": expected,
                    "counted_at": timezone.now(),
                    "counted_by": stock_count_owner(request),
                    "needs_review": needs_review,
                },
            )
        return Response(
            StockCountLineSerializer(
                line,
                context=self.get_serializer_context(),
            ).data
        )

    @action(detail=True, methods=["post"])
    def scan(self, request, pk=None):
        """One article, read off the shelf (§6.6).

        For a serialized variant this replaces ``count`` entirely: nobody types
        a number, because "4" is not an answer to *which four*. The response is
        deliberately thin — what was scanned, and what it is — and says nothing
        about whether it was expected. Telling a counter mid-count that one is a
        surprise turns a blind count into a search for the number the system
        wanted.
        """
        stock_count = self.get_object()
        if stock_count.status != StockCount.Status.IN_PROGRESS:
            return Response(
                {"detail": "Stock count is not in progress."},
                status=status.HTTP_409_CONFLICT,
            )
        payload = request.data or {}
        code = payload.get("code", "")
        variant = None
        if payload.get("variant"):
            variant = ProductVariant.objects.filter(
                pk=payload["variant"]
            ).first()
        with transaction.atomic():
            scan, created = stock_count_tracking.record_scan(
                stock_count,
                code=code,
                variant=variant,
                actor=stock_count_owner(request),
            )
        return Response(
            {
                "id": scan.pk,
                "code": scan.code,
                "created": created,
                "unit": scan.unit_id,
                "variant": scan.variant_id,
                "variant_name": (
                    scan.variant.full_name if scan.variant_id else ""
                ),
                "known": scan.unit_id is not None,
                "line": (
                    StockCountLineSerializer(
                        scan.line, context=self.get_serializer_context()
                    ).data
                    if scan.line_id
                    else None
                ),
            },
            status=(
                status.HTTP_201_CREATED if created else status.HTTP_200_OK
            ),
        )

    @action(detail=True, methods=["get"], url_path="scan-reconciliation")
    def scan_reconciliation(self, request, pk=None):
        """The four findings a scanned count produces, by name (§6.6)."""
        stock_count = self.get_object()
        found = stock_count_tracking.reconcile_scans(stock_count)
        return Response(
            {
                "expected": found["expected"],
                "scanned": found["scanned"],
                "missing": [
                    {
                        "id": unit.pk,
                        "code": unit.code,
                        "variant": unit.variant_id,
                        "variant_name": unit.variant.full_name,
                        "value": str(unit.stock_value),
                    }
                    for unit in found["missing"]
                ],
                "unknown": [
                    {"id": scan.pk, "code": scan.code} for scan in found["unknown"]
                ],
                "relocated": [
                    {
                        "id": scan.pk,
                        "code": scan.code,
                        "unit": scan.unit_id,
                        "warehouse": scan.unit.warehouse_id,
                        "warehouse_name": scan.unit.warehouse.name,
                    }
                    for scan in found["relocated"]
                ],
                "resurrected": [
                    {
                        "id": scan.pk,
                        "code": scan.code,
                        "unit": scan.unit_id,
                        "status": scan.unit.status,
                    }
                    for scan in found["resurrected"]
                ],
                "lots": [
                    {
                        "line": row["line"].pk,
                        "batch": row["line"].batch_id,
                        "batch_code": row["line"].batch.code,
                        "variant": row["line"].variant_id,
                        "variant_name": row["line"].variant.full_name,
                        "remaining": str(row["remaining"]),
                        "counted": str(row["counted"]),
                        "variance": str(row["variance"]),
                        "new_here": row["new_here"],
                    }
                    for row in stock_count_tracking.reconcile_lots(stock_count)
                ],
            }
        )

    @action(detail=True, methods=["get"])
    def reconciliation(self, request, pk=None):
        stock_count = self.get_object()
        lines = stock_count.lines.exclude(
            counted_quantity=F("expected_quantity")
        ).prefetch_related(
            # variant_detail embeds the full ProductVariantSerializer, whose
            # relations (the parent product tree, each image's own FKs, the 1:1
            # stock row) are the serializer's contract — so take them from the
            # shared queryset rather than re-deriving a subset here. Prefetching
            # the forward FK (not select_related) also lets that inner queryset
            # carry its own prefetch chains.
            Prefetch("variant", queryset=variant_detail_queryset()),
        )
        page = self.paginate_queryset(lines)
        if page is not None:
            serializer = StockCountReconciliationLineSerializer(
                page,
                many=True,
                context=self.get_serializer_context(),
            )
            return self.get_paginated_response(serializer.data)
        return Response(
            StockCountReconciliationLineSerializer(
                lines,
                many=True,
                context=self.get_serializer_context(),
            ).data
        )

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        """Abandon a count, or undo one that was applied.

        Undoing an applied count was impossible before, so a miscount rewrote
        the shelf for good. It puts every movement the count made back now —
        and takes the permission that applying it took, rather than the one that
        lets a member of staff drop their own half-walked shelf.
        """
        stock_count = self.get_object()
        if stock_count.doc_status == DocumentStatus.CANCELLED:
            return Response(
                {"detail": "Only an in-progress count can be cancelled."},
                status=status.HTTP_409_CONFLICT,
            )
        stock_count = document_services.cancel(
            stock_count,
            reason=str(request.data.get("reason", "")).strip(),
            request=request,
        )
        record_domain_event(
            name="inventory.stock_count.cancelled",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="stock_count",
            entity_id=stock_count.pk,
            attributes={"scope": stock_count.scope},
        )
        return Response(self._detail_data(stock_count))

    @action(detail=True, methods=["post"])
    def apply(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._apply(request, pk))

    def _apply(self, request, pk=None):
        stock_count = self.get_object()
        if stock_count.status == StockCount.Status.APPLIED:
            # Idempotent no-op even without an Idempotency-Key (double-tap safe).
            return Response(self._detail_data(stock_count))
        if stock_count.status != StockCount.Status.IN_PROGRESS:
            return Response(
                {"detail": "Only an in-progress count can be applied."},
                status=status.HTTP_409_CONFLICT,
            )

        applied_movements = 0
        stale_lines = 0
        with transaction.atomic():
            stock_count = StockCount.objects.select_for_update().get(pk=stock_count.pk)
            if stock_count.status == StockCount.Status.APPLIED:
                return Response(self._detail_data(stock_count))
            if stock_count.status != StockCount.Status.IN_PROGRESS:
                return Response(
                    {"detail": "Only an in-progress count can be applied."},
                    status=status.HTTP_409_CONFLICT,
                )

            # Two things that are not variances, settled before anything is:
            # an article standing in this room whose row said another branch,
            # and one the books had written off. Both are records being put
            # right rather than stock being created or destroyed, and doing
            # them first is what stops the same handset counting as *missing
            # there* and *found here*.
            stock_count_tracking.resurrect_and_relocate(
                stock_count, actor=request.user
            )

            lines = stock_count.lines.select_for_update(
                # ``of="self"`` because the lot is nullable and Postgres
                # refuses ``FOR UPDATE`` on the nullable side of an outer join
                # (``postgres-for-update-nullable-join``). The rows being
                # locked are the count's own lines anyway.
                of=("self",)
            ).select_related(
                "variant",
                "variant__product",
                "batch",
            )
            for line in lines:
                stock_item = lock_stock_item(
                    variant=line.variant, warehouse=stock_count.warehouse_id
                )
                if stock_count_tracking.counts_by_scan(line.variant):
                    # The shelf is the scans, not a number somebody typed, and
                    # both sides are written — **never netted**. One handset
                    # missing and one unrecognised article found is a shelf
                    # that counts the same either way, and a net of zero would
                    # write nothing at all: the missing one still in stock, the
                    # found one still not existing.
                    line.expected_quantity = Decimal(
                        stock_count_tracking.expected_units(
                            stock_count, variant=line.variant
                        ).count()
                    )
                    line.on_hand_at_apply = stock_item.quantity_on_hand
                    line.stale_at_apply = (
                        stock_item.quantity_on_hand != line.expected_quantity
                    )
                    if line.stale_at_apply:
                        stale_lines += 1
                    movement = stock_count_tracking.apply_scanned_line(
                        stock_count, line, actor=request.user
                    )
                    line.movement = movement
                    line.applied = True
                    line.save(
                        update_fields=[
                            "movement",
                            "applied",
                            "stale_at_apply",
                            "on_hand_at_apply",
                            "expected_quantity",
                            "updated_at",
                        ]
                    )
                    if movement is not None:
                        applied_movements += 1
                    continue
                if line.batch_id:
                    # Per balance (§6.6): the lot's stock elsewhere is neither
                    # shown nor touched.
                    line.expected_quantity = stock_count_tracking.lot_line_expected(
                        stock_count, line
                    )
                    current_on_hand = line.expected_quantity
                    delta = line.counted_quantity - line.expected_quantity
                else:
                    current_on_hand = stock_item.quantity_on_hand
                    # Apply the DISCREPANCY the count found, not "set to
                    # counted": this composes correctly with any sale that
                    # landed mid-count.
                    delta = line.counted_quantity - line.expected_quantity
                line.on_hand_at_apply = current_on_hand
                # Flag (never freeze) lines whose stock moved since counting.
                line.stale_at_apply = current_on_hand != line.expected_quantity
                if line.stale_at_apply:
                    stale_lines += 1
                if delta == 0:
                    line.applied = True
                    line.movement = None
                    line.save(
                        update_fields=[
                            "applied",
                            "movement",
                            "stale_at_apply",
                            "on_hand_at_apply",
                            "expected_quantity",
                            "updated_at",
                        ]
                    )
                    continue

                before = stock_snapshot(stock_item)
                if delta > 0:
                    movement_type = StockMovement.Type.INCREASE
                else:
                    movement_type = StockMovement.Type.DECREASE
                    if stock_item.quantity_on_hand + delta < 0:
                        raise serializers.ValidationError(
                            {
                                "variant": (
                                    f"Applying the count would make "
                                    f"{line.variant.sku} negative."
                                )
                            }
                        )
                stock_item.quantity_on_hand = stock_item.quantity_on_hand + delta
                save_stock_item_quantities(stock_item)
                plan = allocate_adjustment(
                    variant=line.variant,
                    warehouse=stock_item.warehouse_id,
                    delta=delta,
                    batches=[line.batch_id] if line.batch_id else None,
                    placeholder_key=f"SC-{stock_count.pk}-{line.pk}",
                    what="هذا الجرد",
                )
                movement = create_stock_movement(
                    stock_item=stock_item,
                    movement_type=movement_type,
                    quantity=abs(delta),
                    note=f"جرد المخزون {stock_count.count_number}",
                    created_by=request.user,
                    before=before,
                    variant=line.variant,
                    voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
                    voucher_id=stock_count.pk,
                    tracked_plan=plan,
                )
                line.movement = movement
                line.applied = True
                line.save(
                    update_fields=[
                        "movement",
                        "applied",
                        "stale_at_apply",
                        "on_hand_at_apply",
                        "expected_quantity",
                        "updated_at",
                    ]
                )
                applied_movements += 1

            # Applying is what submits a count: it is the moment the shelf
            # actually changes. The lifecycle stamps who and when, recomputes
            # the progress field, and writes the trail.
            stock_count = document_services.submit(stock_count, request=request)
            record_domain_event(
                name="inventory.stock_count.applied",
                event_type=AnalyticsEvent.EventType.AUDIT,
                severity=(
                    AnalyticsEvent.Severity.WARNING
                    if stale_lines
                    else AnalyticsEvent.Severity.INFO
                ),
                user=request.user,
                entity_type="stock_count",
                entity_id=stock_count.pk,
                attributes={
                    "scope": stock_count.scope,
                    "category_id": stock_count.category_id,
                    "stale_lines": stale_lines,
                },
                metrics={
                    "applied_movements": applied_movements,
                    "line_count": stock_count.lines.count(),
                },
            )
        return Response(self._detail_data(stock_count))


class WarehouseViewSet(viewsets.ModelViewSet):
    """Where a shop keeps its stock.

    Flat by design (``WAREHOUSES_PLAN.md`` §3.1): no parent, no groups, no tree
    to convert between. A shop has a showroom, perhaps a store room, perhaps a
    van, and ERPNext's nested set would buy it nothing but the conversion bugs
    that come with one.
    """

    serializer_class = WarehouseSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_warehouse",),
        "retrieve": ("inventory.view_warehouse",),
        "create": ("inventory.add_warehouse",),
        "update": ("inventory.change_warehouse",),
        "partial_update": ("inventory.change_warehouse",),
        "destroy": ("inventory.delete_warehouse",),
    }
    queryset = Warehouse.objects.annotate(
        # The row shows how much is kept here, and why it cannot be deleted;
        # both are per-row questions, and asking them per row would be four
        # queries per warehouse on a list that exists to be read at a glance.
        stock_item_count=Count(
            "stock_items",
            filter=Q(stock_items__quantity_on_hand__gt=0),
            distinct=True,
        ),
        **Warehouse.blocker_annotations(),
    )
    filterset_fields = ("kind", "is_active", "is_default")
    search_fields = ("name", "code")
    ordering_fields = ("name", "code", "created_at")

    def perform_destroy(self, instance):
        """Refuse rather than cascade.

        ERPNext's ``Warehouse.on_trash`` blocks on quantity and on ledger
        entries, and then *unlinks* the warehouse from anything naming it as a
        default. We refuse that last part too: silently detaching a reference is
        how a shop finds out later that a number moved.
        """
        blockers = instance.deletion_blockers()
        if blockers:
            raise serializers.ValidationError(
                {
                    "detail": "لا يمكن حذف هذا المخزن.",
                    "blockers": blockers,
                }
            )
        instance.delete()


class StockTransferViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    """Moving stock between a shop's own places.

    No update verb, deliberately. A draft transfer is edited by rebuilding it;
    a dispatched one is a submitted document and is corrected by cancelling and
    re-sending, which is what ``Correction.COUNTER`` on its registration says.
    """

    serializer_class = StockTransferSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stocktransfer",),
        "retrieve": ("inventory.view_stocktransfer",),
        "create": ("inventory.add_stocktransfer",),
        "send_off": ("inventory.dispatch_stocktransfer",),
        "receive": ("inventory.receive_stocktransfer",),
        "cancel": ("inventory.dispatch_stocktransfer",),
    }
    queryset = StockTransfer.objects.select_related(
        "source", "destination"
    ).with_lifecycle_relations().prefetch_related(
        Prefetch(
            "lines",
            queryset=StockTransferLine.objects.select_related(
                "variant", "variant__product"
            ),
        ),
        # Every line renders its variant's ``full_name``, which falls back to
        # ``option_values_label`` -> the option_values M2M. Unprefetched that is
        # a query per line, which on a list of transfers is a query per row.
        "lines__variant__option_values__option",
    )
    filterset_fields = ("status", "source", "destination")
    ordering_fields = ("created_at", "dispatched_at")

    # NOT named ``dispatch``: that is ``View.dispatch``, the entry point every
    # request goes through, and shadowing it breaks the whole viewset silently.
    @action(detail=True, methods=["post"], url_path="dispatch")
    def send_off(self, request, pk=None):
        # ``picks`` is ``{line_id: {"unit_ids"|"unit_codes"|"batch_ids": [...]}}``
        # — which handsets, and out of which lots, this van is carrying.
        transfer = transfer_services.dispatch_transfer(
            self.get_object(),
            request=request,
            picks=(request.data or {}).get("picks"),
        )
        return Response(self.get_serializer(transfer).data)

    @action(detail=True, methods=["post"])
    def receive(self, request, pk=None):
        transfer = self.get_object()
        serializer = StockTransferReceiptLineInputSerializer(
            data=request.data.get("lines", []), many=True
        )
        serializer.is_valid(raise_exception=True)
        rows = [
            (row["line"], row["quantity"]) for row in serializer.validated_data
        ]
        for line, _ in rows:
            if line.transfer_id != transfer.pk:
                raise serializers.ValidationError(
                    {"lines": "هذا السطر لا ينتمي إلى هذا التحويل."}
                )
        transfer_services.receive_transfer(
            transfer,
            lines=rows,
            request=request,
            note=request.data.get("note", ""),
            picks=(request.data or {}).get("picks"),
        )
        transfer.refresh_from_db()
        return Response(self.get_serializer(transfer).data)

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        reason = (request.data.get("reason") or "").strip()
        if not reason:
            raise serializers.ValidationError({"reason": "السبب مطلوب."})
        transfer = document_services.cancel(
            self.get_object(), reason=reason, request=request
        )
        return Response(self.get_serializer(transfer).data)
