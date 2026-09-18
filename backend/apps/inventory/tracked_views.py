"""Read surfaces for identified stock, and the two writes a human owns.

Deliberately thin. Almost everything that happens to a unit or a lot happens
because a *document* moved stock — a receipt, a sale, a transfer — and those go
through ``apps.inventory.tracking`` from the services that own them. What is
left over is what a person legitimately does to an article of stock without
moving it: price it, describe it, give it the identifier it has been owing, and
stop a lot from being sold.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

import django_filters
from django.db.models import Prefetch, Q, Sum
from django.utils import timezone
from rest_framework import mixins, serializers, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from . import tracking
from .identity import KIND_UNIT, TrackingConflict, conflict_error
from .models import StockAllocation, StockBatch, StockBatchBalance, StockUnit
from .tracked_serializers import (
    IdentifyUnitSerializer,
    StockAllocationSerializer,
    StockBatchBalanceSerializer,
    StockBatchSerializer,
    StockUnitLookupSerializer,
    StockUnitSerializer,
)


def _selling_warehouse_id(request):
    """Where the till asking this question actually sells from.

    The client does not know its own warehouse — the register profile does, and
    the backend already resolves it for every checkout. A picker that guessed
    would offer the cashier goods sitting in another branch, which is offering
    something they cannot hand over.
    """
    from apps.sales.registers import selling_warehouse_id

    return selling_warehouse_id(request)


class StockUnitFilter(django_filters.FilterSet):
    product = django_filters.NumberFilter(field_name="variant__product_id")
    code = django_filters.CharFilter(method="filter_code")
    supplier = django_filters.NumberFilter(field_name="supplier_id")
    in_stock = django_filters.BooleanFilter(method="filter_in_stock")

    class Meta:
        model = StockUnit
        fields = (
            "variant",
            "product",
            "status",
            "warehouse",
            "batch",
            "is_identified",
            "is_consignment",
            "supplier",
        )

    def filter_code(self, queryset, name, value):
        """Match either identifier, normalised.

        A dual-SIM handset is scanned off whichever of its two IMEIs the box
        happens to show, and a search that only knew the first would send it
        back out of the door untracked.
        """
        from .identity import normalize_identifier

        normalized = normalize_identifier(value)
        if not normalized:
            return queryset
        return queryset.filter(code_normalized__startswith=normalized) | (
            queryset.filter(secondary_code_normalized__startswith=normalized)
        )

    def filter_in_stock(self, queryset, name, value):
        if value is None:
            return queryset
        if value:
            return queryset.filter(status__in=StockUnit.ON_HAND_STATUSES)
        return queryset.exclude(status__in=StockUnit.ON_HAND_STATUSES)


def _warranty_answer(unit):
    """What a counter needs when somebody puts a handset on the desk.

    ``None`` for an article nobody ever sold, because "no warranty" and "we have
    never seen this" are different answers and only one of them is true.
    """
    if unit is None or unit.sold_at is None:
        return None
    today = timezone.localdate()
    expires_on = unit.warranty_expires_on
    from apps.operations.models import Job

    # Repairs the shop did to this article, whichever side it was on: work it
    # did while the handset was its own stock, and work it did on the same
    # handset once the customer owned it. ERPNext keeps a stored
    # ``maintenance_status``; this is derived, because a stored one is wrong the
    # day after the warranty expires.
    worked_on = Q(stock_unit=unit)
    if unit.asset_id:
        worked_on |= Q(job_assets__asset_id=unit.asset_id)
    repairs = Job.objects.filter(worked_on).distinct().count()
    return {
        "sold_at": unit.sold_at,
        "customer": unit.customer_id,
        "expires_on": expires_on,
        "is_covered": expires_on is not None and expires_on >= today,
        "days_remaining": (expires_on - today).days if expires_on else None,
        "repair_count": repairs,
    }


class StockUnitViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    viewsets.GenericViewSet,
):
    """Every article of stock this shop has ever identified.

    No create and no destroy: a unit is born at a receipt or a counter purchase
    and it is never deleted, because the row is the only record that the
    identifier was ever here. Write-off and cancellation are *statuses*, and
    they go through the services that also move the stock.
    """

    serializer_class = StockUnitSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockunit",),
        "retrieve": ("inventory.view_stockunit",),
        "history": ("inventory.view_stockunit",),
        "lookup": ("inventory.view_stockunit",),
        "summary": ("inventory.view_stockunit",),
        "update": ("inventory.change_stockunit",),
        "partial_update": ("inventory.change_stockunit",),
        "identify": ("inventory.add_stockunit",),
        "bulk_reprice": ("inventory.reprice_stockunit",),
        "write_off": ("inventory.write_off_stockunit",),
        "consignment_payables": ("inventory.view_consignment_liability",),
        "disburse_payout": ("inventory.disburse_consignment_payout",),
        "resend_consignor_sms": ("inventory.view_consignment_liability",),
        "return_to_consignor": ("inventory.manage_consignmentagreement",),
    }
    filterset_class = StockUnitFilter
    # Keyset-friendly and stable: newest arrival first, id as the tiebreak. The
    # lesson of ``purchases-screen-perf`` — an offset page over a six-figure
    # table is a screen that gets slower every month it is used.
    ordering = ("-in_stock_since", "-id")
    search_fields = ("code", "secondary_code", "supplier_code")

    def get_queryset(self):
        query = StockUnit.objects.select_related(
            "variant",
            "variant__product",
            "warehouse",
            "batch",
        ).order_by(*self.ordering)
        if self.request.query_params.get("for_sale") in ("1", "true", "True"):
            # The till's own shelf: in stock, identified, here. Everything the
            # picker must not offer is excluded by the query rather than by the
            # widget, so a stale list cannot become a sale of something that is
            # not there.
            query = query.filter(
                warehouse_id=_selling_warehouse_id(self.request),
                status=StockUnit.Status.IN_STOCK,
                is_identified=True,
            )
        return query

    @action(detail=True, methods=["get"])
    def history(self, request, pk=None):
        """Where this article has been, in one query.

        The whole reason an allocation is a row rather than a text field on a
        sale line: *"where has this IMEI been"* is
        ``filter(unit=...).order_by("posting_at")`` and nothing else.
        """
        unit = self.get_object()
        rows = (
            StockAllocation.objects.filter(unit=unit)
            .select_related("batch", "warehouse")
            .order_by("posting_at", "id")
        )
        return Response(
            StockAllocationSerializer(rows, many=True, context={"request": request}).data
        )

    @action(detail=False, methods=["post"])
    def lookup(self, request):
        """A scanned identifier, answered.

        Three outcomes, and the difference between them is the whole of §4.4: a
        live unit (here it is), a historical one (we sold this — is it the same
        device?), or nothing at all.
        """
        serializer = StockUnitLookupSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        code = serializer.validated_data["code"]
        unit = tracking.find_live_unit(code)
        history = tracking.historical_units(code)
        # A counter lookup by IMEI is usually a warranty question, so the answer
        # comes with the answer: sold on X to Y, covered until Z, repaired
        # twice. Derived, never stored — ERPNext keeps a ``maintenance_status``
        # column and it is wrong the day after the warranty expires.
        subject = unit or (history[0] if history else None)
        return Response(
            {
                "unit": (
                    StockUnitSerializer(unit, context={"request": request}).data
                    if unit is not None
                    else None
                ),
                "history": StockUnitSerializer(
                    history, many=True, context={"request": request}
                ).data,
                "warranty": _warranty_answer(subject),
            }
        )

    @action(detail=False, methods=["get"])
    def summary(self, request):
        """Counts by status, plus what is still owing an identifier."""
        rows = (
            self.filter_queryset(self.get_queryset())
            .values("status")
            .annotate(total=Sum(1))
        )
        return Response(
            {
                "by_status": {row["status"]: row["total"] for row in rows},
                "missing_identifiers": self.filter_queryset(self.get_queryset())
                .filter(is_identified=False, status__in=StockUnit.LIVE_STATUSES)
                .count(),
            }
        )

    @action(detail=True, methods=["post"])
    def identify(self, request, pk=None):
        """Give a placeholder the identifier it has been owing.

        The other half of *capture later*. A live duplicate is refused with the
        same structured conflict a receipt would raise, because the answer the
        person needs — *«افتح الجهاز الموجود»* — is the same one either way.
        """
        unit = self.get_object()
        serializer = IdentifyUnitSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        code = serializer.validated_data["code"]

        if unit.is_identified:
            raise serializers.ValidationError(
                {"detail": f"الوحدة {unit.code} لها معرّف بالفعل."}
            )
        existing = tracking.find_live_unit(code)
        if existing is not None and existing.pk != unit.pk:
            raise serializers.ValidationError(
                conflict_error(
                    [
                        TrackingConflict(
                            field="code",
                            value=existing.code_normalized,
                            kind=KIND_UNIT,
                            message=(
                                f"المعرّف {existing.code} مسجّل بالفعل على وحدة "
                                "في المخزون."
                            ),
                            object_id=existing.pk,
                            label=existing.variant.full_name,
                        )
                    ]
                )
            )

        unit.code = code
        unit.secondary_code = serializer.validated_data.get("secondary_code", "")
        if serializer.validated_data.get("identifier_kind"):
            unit.identifier_kind = serializer.validated_data["identifier_kind"]
        unit.is_identified = True
        unit.save(
            update_fields=[
                "code",
                "code_normalized",
                "secondary_code",
                "secondary_code_normalized",
                "identifier_kind",
                "is_identified",
                "updated_at",
            ]
        )
        return Response(
            {
                **StockUnitSerializer(unit, context={"request": request}).data,
                "identifier_warnings": serializer.validated_data[
                    "identifier_warnings"
                ],
            }
        )


    # -- pricing and disposal ------------------------------------------------

    @action(detail=False, methods=["post"], url_path="bulk-reprice")
    def bulk_reprice(self, request):
        """Re-price a shelf's worth of articles in one write.

        A used-goods trader marks down every handset over ninety days old at
        once, and doing that a row at a time is how it does not get done.
        Follows the bulk-operations pattern: explicit ids, one statement, and
        the count of what actually changed.
        """
        from .tracked_serializers import BulkRepriceSerializer

        serializer = BulkRepriceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        units = list(
            StockUnit.objects.filter(
                pk__in=data["ids"], status__in=StockUnit.ON_HAND_STATUSES
            ).select_related("variant")
        )
        price = data.get("price")
        percent = data.get("percent")
        changed = []
        for unit in units:
            if price is not None:
                new_price = price
            else:
                # A markdown reads off whatever the article is actually asking
                # today — its own price if it has one, the variant's if not —
                # because a percentage of a price nobody quoted is a number
                # nobody chose.
                base = unit.list_price
                if base is None:
                    base = unit.variant.unit_price
                new_price = (base * (Decimal("100") + percent) / Decimal("100")).quantize(
                    Decimal("0.01")
                )
                new_price = max(new_price, Decimal("0.00"))
            if unit.list_price != new_price:
                unit.list_price = new_price
                changed.append(unit)
        if changed:
            StockUnit.objects.bulk_update(changed, ["list_price", "updated_at"])
        return Response({"updated": len(changed), "requested": len(data["ids"])})

    @action(detail=True, methods=["post"], url_path="write-off")
    def write_off(self, request, pk=None):
        """Take an article off the shelf because it is gone, or broken.

        Stock leaves, so this is a movement rather than a status flip: the bin
        drops by one and the ledger says why. A shop that could set the status
        alone would have a unit nobody can find and a quantity that still counts
        it.
        """
        from .tracked_writeoff import write_off_unit

        unit = self.get_object()
        reason = (request.data or {}).get("reason", "")
        if not str(reason).strip():
            raise serializers.ValidationError({"reason": "اذكر سبب الشطب."})
        unit = write_off_unit(unit, reason=str(reason).strip(), request=request)
        return Response(
            StockUnitSerializer(unit, context={"request": request}).data
        )

    # -- consignment ---------------------------------------------------------

    @action(detail=False, methods=["get"], url_path="consignment-payables")
    def consignment_payables(self, request):
        """مستحقات الأمانات — sold goods nobody has been paid for."""
        from . import consignment as figures
        from .consignment_serializers import ConsignmentPayableSerializer

        rows = (
            figures.payable_units(
                consignor=request.query_params.get("consignor") or None
            )
            .select_related(
                "variant",
                "variant__product",
                "consignor",
                "sold_order_line",
                "sold_order_line__order",
            )
            .order_by("sold_at", "id")
        )
        return Response(
            {
                "results": ConsignmentPayableSerializer(
                    rows, many=True, context={"request": request}
                ).data,
                "total_due": figures.consignor_payable(),
            }
        )

    @action(detail=True, methods=["post"], url_path="disburse-payout")
    def disburse_payout(self, request, pk=None):
        """Hand this consignor their money, and close the payable.

        ``units`` in the body settles several of the same consignor's articles
        on one voucher, which is what a counter actually does: the owner of
        eight handbags collects for three of them and signs once.
        """
        from . import consignment_service
        from .consignment_serializers import (
            ConsignorPayoutSerializer,
            DisbursePayoutSerializer,
        )

        unit = self.get_object()
        payload = dict(request.data or {})
        payload.setdefault("units", [])
        payload["units"] = sorted({int(unit.pk), *map(int, payload["units"] or [])})
        serializer = DisbursePayoutSerializer(data=payload)
        serializer.is_valid(raise_exception=True)
        payout = consignment_service.disburse_payout(
            # Ids, not rows: the service locks them inside its own transaction,
            # and a queryset evaluated here would take no lock at all.
            unit_ids=serializer.validated_data["units"],
            method=serializer.validated_data["method"],
            reference=serializer.validated_data["reference"],
            notes=serializer.validated_data["notes"],
            request=request,
        )
        return Response(
            ConsignorPayoutSerializer(payout, context={"request": request}).data
        )

    @action(detail=True, methods=["post"], url_path="resend-consignor-sms")
    def resend_consignor_sms(self, request, pk=None):
        """Send the "your goods sold" message again.

        Idempotent by the same dedup key the sale used, so tapping it twice
        queues one message rather than two.
        """
        from . import consignment_service

        unit = self.get_object()
        message = consignment_service.resend_sale_sms(unit)
        return Response(
            {
                "queued": message is not None,
                "status": getattr(message, "status", ""),
            }
        )

    @action(detail=True, methods=["post"], url_path="return-to-consignor")
    def return_to_consignor(self, request, pk=None):
        """Give unsold goods back to the person who left them."""
        from . import consignment_service

        unit = self.get_object()
        unit = consignment_service.return_to_consignor(
            unit, request=request, note=(request.data or {}).get("note", "")
        )
        return Response(
            StockUnitSerializer(unit, context={"request": request}).data
        )


class StockBatchFilter(django_filters.FilterSet):
    product = django_filters.NumberFilter(field_name="variant__product_id")
    # "Has a balance there", not a scope: a lot is never *in* a warehouse, its
    # goods are.
    warehouse = django_filters.NumberFilter(method="filter_warehouse")
    is_expired = django_filters.BooleanFilter(method="filter_is_expired")
    expires_before = django_filters.DateFilter(
        field_name="expiry_date", lookup_expr="lte"
    )
    expires_after = django_filters.DateFilter(
        field_name="expiry_date", lookup_expr="gte"
    )

    class Meta:
        model = StockBatch
        fields = ("variant", "product", "status", "is_locked", "supplier")

    def filter_warehouse(self, queryset, name, value):
        return queryset.filter(balances__warehouse_id=value).distinct()

    def filter_is_expired(self, queryset, name, value):
        if value is None:
            return queryset
        today = timezone.localdate()
        if value:
            return queryset.filter(expiry_date__lt=today)
        return queryset.filter(expiry_date__isnull=True) | queryset.filter(
            expiry_date__gte=today
        )


class StockBatchViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    viewsets.GenericViewSet,
):
    """The lots this shop has held, wherever their goods currently sit.

    The **lot** is the resource here, not the lot-in-a-place. A recall is one
    row; where its goods are is ``/balances/``.
    """

    serializer_class = StockBatchSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockbatch",),
        "retrieve": ("inventory.view_stockbatch",),
        "balances": ("inventory.view_stockbatch",),
        "history": ("inventory.view_stockbatch",),
        "expiry_watchlist": ("inventory.view_stockbatch",),
        "update": ("inventory.manage_batches",),
        "partial_update": ("inventory.manage_batches",),
        "quarantine": ("inventory.quarantine_batch",),
        "release_quarantine": ("inventory.quarantine_batch",),
    }
    filterset_class = StockBatchFilter
    ordering = ("expiry_date", "id")

    def get_queryset(self):
        for_sale = self.request.query_params.get("for_sale") in (
            "1",
            "true",
            "True",
        )
        warehouse_id = _selling_warehouse_id(self.request) if for_sale else None
        balances = StockBatchBalance.objects.select_related("warehouse")
        if for_sale:
            balances = balances.filter(warehouse_id=warehouse_id)
        query = (
            StockBatch.objects.select_related(
                "variant", "variant__product", "supplier"
            )
            .prefetch_related(Prefetch("balances", queryset=balances))
            .annotate(
                on_hand=Sum(
                    "balances__remaining_quantity",
                    filter=(
                        Q(balances__warehouse_id=warehouse_id)
                        if for_sale
                        else None
                    ),
                )
            )
            .order_by(*self.ordering)
        )
        if for_sale:
            # Sellable, here, and not empty. A lot whose goods are all in
            # another branch is not on this shelf.
            query = query.filter(
                status=StockBatch.Status.ACTIVE,
                is_locked=False,
                balances__warehouse_id=warehouse_id,
                balances__remaining_quantity__gt=0,
            ).distinct()
        return query

    @action(detail=True, methods=["get"])
    def balances(self, request, pk=None):
        """Where Lot A is, and how much of it — including the places it has
        left, which is exactly the sentence a recall needs."""
        batch = self.get_object()
        rows = batch.balances.select_related("warehouse").order_by(
            "-remaining_quantity", "id"
        )
        return Response(
            StockBatchBalanceSerializer(
                rows, many=True, context={"request": request}
            ).data
        )

    @action(detail=True, methods=["get"])
    def history(self, request, pk=None):
        """This lot's movements, in every warehouse, from one row."""
        batch = self.get_object()
        rows = (
            StockAllocation.objects.filter(batch=batch)
            .select_related("unit", "warehouse")
            .order_by("posting_at", "id")
        )
        return Response(
            StockAllocationSerializer(
                rows, many=True, context={"request": request}
            ).data
        )

    @action(detail=True, methods=["post"])
    def quarantine(self, request, pk=None):
        """Stop-sale, everywhere, in one write.

        The reason status lives on the identity rather than on each balance: a
        recall that has to lock three rows has a window in between where the
        second branch is still selling.
        """
        batch = self.get_object()
        batch.status = StockBatch.Status.QUARANTINED
        batch.is_locked = True
        batch.save(update_fields=["status", "is_locked", "updated_at"])
        return Response(
            StockBatchSerializer(
                self.get_queryset().get(pk=batch.pk), context={"request": request}
            ).data
        )

    @action(detail=True, methods=["post"], url_path="release-quarantine")
    def release_quarantine(self, request, pk=None):
        batch = self.get_object()
        batch.status = StockBatch.Status.ACTIVE
        batch.is_locked = False
        batch.save(update_fields=["status", "is_locked", "updated_at"])
        return Response(
            StockBatchSerializer(
                self.get_queryset().get(pk=batch.pk), context={"request": request}
            ).data
        )

    @action(detail=False, methods=["get"], url_path="expiry-watchlist")
    def expiry_watchlist(self, request):
        """Lots expiring within N days that still have goods somewhere."""
        try:
            days = int(request.query_params.get("days", 30))
        except (TypeError, ValueError):
            days = 30
        horizon = timezone.localdate() + timedelta(days=max(days, 0))
        rows = (
            self.get_queryset()
            .filter(expiry_date__isnull=False, expiry_date__lte=horizon)
            .filter(on_hand__gt=0)
        )
        page = self.paginate_queryset(rows)
        serializer = StockBatchSerializer(
            page if page is not None else rows,
            many=True,
            context={"request": request},
        )
        if page is not None:
            return self.get_paginated_response(serializer.data)
        return Response(serializer.data)
