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
from apps.core.models import ShopSettings
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility
from .models import StockCount, StockCountLine, StockItem, StockMovement
from .serializers import StockItemSerializer, StockMovementSerializer
from .services import (
    consume_expiring_stock_batches,
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_count_needs_review,
    stock_snapshot,
)
from .stock_count_serializers import (
    StockCountDetailSerializer,
    StockCountLineInputSerializer,
    StockCountLineSerializer,
    StockCountReconciliationLineSerializer,
    StockCountSerializer,
    StockCountStartSerializer,
)


class StockItemFilter(django_filters.FilterSet):
    product = django_filters.NumberFilter(field_name="variant__product_id")

    class Meta:
        model = StockItem
        fields = ("product", "variant")


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

        with transaction.atomic():
            stock_item, _ = StockItem.objects.select_for_update().get_or_create(
                variant=variant,
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
            if movement_type in (
                StockMovement.Type.DECREASE,
                StockMovement.Type.DAMAGED,
            ):
                consume_expiring_stock_batches(variant=variant, quantity=quantity)
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
        "cancel": ("inventory.change_stockcount",),
        "apply": ("inventory.apply_stockcount",),
    }
    queryset = StockCount.objects.select_related("owner", "applied_by", "category")
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

        shop_settings = ShopSettings.load()
        with transaction.atomic():
            stock_item = lock_stock_item(variant=variant)
            expected = stock_item.quantity_on_hand
            existing = (
                StockCountLine.objects.select_for_update()
                .filter(stock_count=stock_count, variant=variant)
                .first()
            )
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
        stock_count = self.get_object()
        if stock_count.status != StockCount.Status.IN_PROGRESS:
            return Response(
                {"detail": "Only an in-progress count can be cancelled."},
                status=status.HTTP_409_CONFLICT,
            )
        stock_count.status = StockCount.Status.CANCELLED
        stock_count.cancelled_at = timezone.now()
        stock_count.save(update_fields=["status", "cancelled_at", "updated_at"])
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

            lines = stock_count.lines.select_for_update().select_related(
                "variant",
                "variant__product",
            )
            for line in lines:
                stock_item = lock_stock_item(variant=line.variant)
                current_on_hand = stock_item.quantity_on_hand
                line.on_hand_at_apply = current_on_hand
                # Flag (never freeze) lines whose stock moved since counting.
                line.stale_at_apply = current_on_hand != line.expected_quantity
                if line.stale_at_apply:
                    stale_lines += 1

                # Apply the DISCREPANCY the count found, not "set to counted":
                # this composes correctly with any sale that landed mid-count.
                delta = line.counted_quantity - line.expected_quantity
                if delta == 0:
                    line.applied = True
                    line.movement = None
                    line.save(
                        update_fields=[
                            "applied",
                            "movement",
                            "stale_at_apply",
                            "on_hand_at_apply",
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
                if movement_type == StockMovement.Type.DECREASE:
                    consume_expiring_stock_batches(
                        variant=line.variant,
                        quantity=abs(delta),
                    )
                movement = create_stock_movement(
                    stock_item=stock_item,
                    movement_type=movement_type,
                    quantity=abs(delta),
                    note=f"جرد المخزون {stock_count.count_number}",
                    created_by=request.user,
                    before=before,
                    variant=line.variant,
                )
                line.movement = movement
                line.applied = True
                line.save(
                    update_fields=[
                        "movement",
                        "applied",
                        "stale_at_apply",
                        "on_hand_at_apply",
                        "updated_at",
                    ]
                )
                applied_movements += 1

            stock_count.status = StockCount.Status.APPLIED
            stock_count.applied_by = stock_count_owner(request)
            stock_count.applied_at = timezone.now()
            stock_count.save(
                update_fields=["status", "applied_by", "applied_at", "updated_at"]
            )
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
