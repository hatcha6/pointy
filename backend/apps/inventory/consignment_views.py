"""The consignment endpoints.

Three surfaces: the signed voucher, the payables screen, and the position. All
three read their money from :mod:`apps.inventory.consignment`, which is the only
module that knows how a payout is computed — a screen that did its own
arithmetic would be a fifth definition of a number that has exactly one.
"""

from __future__ import annotations

import django_filters
from django.db.models import Count
from rest_framework import mixins, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission

from . import consignment as figures
from . import consignment_service
from .consignment_serializers import (
    AssessIncidentSerializer,
    ConsignmentAgreementSerializer,
    ConsignmentIncidentSerializer,
    ConsignmentIntakeSerializer,
    ConsignmentPayableSerializer,
    ConsignorPayoutSerializer,
    SettleIncidentSerializer,
    UnitAttributeDefinitionSerializer,
)
from .models import (
    ConsignmentAgreement,
    ConsignmentIncident,
    ConsignorPayout,
    StockUnit,
    UnitAttributeDefinition,
)


class ConsignmentAgreementFilter(django_filters.FilterSet):
    open_only = django_filters.BooleanFilter(method="filter_open")

    class Meta:
        model = ConsignmentAgreement
        fields = ("consignor", "doc_status", "payout_mode", "liability_policy")

    def filter_open(self, queryset, name, value):
        """Agreements with goods still on the shelf.

        Derived rather than stored: "are any of its units still here?" is one
        indexed existence check, and a status column would be a second answer
        that can disagree with the first.
        """
        if not value:
            return queryset
        return queryset.filter(
            units__status__in=StockUnit.LIVE_STATUSES
        ).distinct()


class ConsignmentAgreementViewSet(viewsets.ModelViewSet):
    """سند استلام أمانة — created, signed, and eventually closed.

    Creating one is a draft: the terms are argued over across a counter before
    anybody signs. Submitting it is what puts the goods on the shelf and starts
    the shop's promise about them, which is why the intake items ride on the
    submit rather than on the create.
    """

    serializer_class = ConsignmentAgreementSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_consignmentagreement",),
        "retrieve": ("inventory.view_consignmentagreement",),
        "statement": ("inventory.view_consignment_liability",),
        "create": ("inventory.manage_consignmentagreement",),
        "update": ("inventory.manage_consignmentagreement",),
        "partial_update": ("inventory.manage_consignmentagreement",),
        "destroy": ("inventory.manage_consignmentagreement",),
        "submit": ("inventory.manage_consignmentagreement",),
    }
    filterset_class = ConsignmentAgreementFilter
    ordering = ("-signed_at", "-id")
    search_fields = ("number", "consignor__full_name", "consignor__phone")

    def get_queryset(self):
        return (
            ConsignmentAgreement.objects.select_related("consignor")
            # ``variant.full_name`` reads the option values; without them a
            # detail with eight handbags on it is eight extra queries.
            .prefetch_related(
                "units__variant__product",
                "units__variant__option_values__option",
            )
            .order_by(*self.ordering)
        )

    def get_serializer_context(self):
        context = super().get_serializer_context()
        # A list row is not a document: the units belong on the detail, and
        # sending them with every row is how a list screen starts timing out.
        context["with_units"] = self.action != "list"
        return context

    def perform_create(self, serializer):
        serializer.validated_data.pop("items", None)
        serializer.save(created_by=self.request.user)

    @action(detail=True, methods=["post"])
    def submit(self, request, pk=None):
        """Sign it, and take the goods in.

        One act: the voucher, the units and the stock movement are written
        inside one transaction, because a signed page with no goods behind it is
        a promise about nothing and goods with no page behind them are a
        liability nobody wrote down.
        """
        agreement = self.get_object()
        # The items alone, validated against their own serializer: running the
        # agreement's through here would re-check terms that were agreed and
        # saved when the draft was written, and refuse a submit for a
        # ``payout_rate`` that is sitting on the row in front of it.
        items = ConsignmentIntakeSerializer(data=request.data)
        items.is_valid(raise_exception=True)
        agreement, units = consignment_service.submit_agreement(
            agreement,
            items=items.validated_data.get("items"),
            request=request,
        )
        agreement.refresh_from_db()
        return Response(
            self.get_serializer(agreement).data,
        )

    @action(detail=True, methods=["get"])
    def statement(self, request, pk=None):
        """One consignor's page: everything in, sold, paid, and still owed.

        The page a consignor is handed across the counter when they ask, which
        is why it is one call rather than four screens they have to be walked
        through.
        """
        agreement = self.get_object()
        units = list(
            agreement.units.select_related("variant", "variant__product").all()
        )
        held = [unit for unit in units if unit.status in StockUnit.ON_HAND_STATUSES]
        sold = [unit for unit in units if unit.status == StockUnit.Status.SOLD]
        unpaid = [unit for unit in sold if unit.consignor_paid_at is None]
        paid = [unit for unit in sold if unit.consignor_paid_at is not None]
        return Response(
            {
                "agreement": self.get_serializer(agreement).data,
                "held_count": len(held),
                "sold_count": len(sold),
                "declared_value": sum(
                    (unit.declared_value or 0 for unit in held), 0
                ),
                "paid_total": sum(
                    (figures.consignor_payout_due(unit) for unit in paid), 0
                ),
                "payable_total": sum(
                    (figures.consignor_payout_due(unit) for unit in unpaid), 0
                ),
                "commission_total": sum(
                    (
                        (unit.sold_price or 0) - figures.consignor_payout_due(unit)
                        for unit in sold
                    ),
                    0,
                ),
                "lines": ConsignmentPayableSerializer(
                    sold, many=True, context={"request": request}
                ).data,
            }
        )


class ConsignorPayoutViewSet(
    mixins.ListModelMixin, mixins.RetrieveModelMixin, viewsets.GenericViewSet
):
    """سند صرف أمانة — read-only here; one is created by disbursing."""

    serializer_class = ConsignorPayoutSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_consignment_liability",),
        "retrieve": ("inventory.view_consignment_liability",),
    }
    filterset_fields = ("consignor", "method", "doc_status")
    ordering = ("-paid_at", "-id")
    search_fields = ("number", "consignor__full_name", "reference")

    def get_queryset(self):
        return (
            ConsignorPayout.objects.select_related("consignor")
            # The articles ride along: every row prints what it paid for, so a
            # list of twenty payouts must not be twenty extra queries — the
            # option values included, because ``full_name`` reads them.
            .prefetch_related(
                "units__variant__product",
                "units__variant__option_values__option",
            )
            .order_by(*self.ordering)
        )


class ConsignmentIncidentFilter(django_filters.FilterSet):
    open_only = django_filters.BooleanFilter(method="filter_open")
    unassessed = django_filters.BooleanFilter(method="filter_unassessed")
    consignor = django_filters.NumberFilter(field_name="unit__consignor_id")

    class Meta:
        model = ConsignmentIncident
        fields = ("kind", "responsibility", "resolution", "agreement")

    def filter_open(self, queryset, name, value):
        if value is None:
            return queryset
        query = {"resolution__in": ConsignmentIncident.OPEN_RESOLUTIONS}
        return queryset.filter(**query) if value else queryset.exclude(**query)

    def filter_unassessed(self, queryset, name, value):
        if value is None:
            return queryset
        return queryset.filter(
            is_assessed=not value,
            resolution__in=ConsignmentIncident.OPEN_RESOLUTIONS,
        )


class ConsignmentIncidentViewSet(
    mixins.ListModelMixin, mixins.RetrieveModelMixin, viewsets.GenericViewSet
):
    """محضر حادث أمانة — the record, the assessment and the settlement.

    Created from the unit rather than here: an incident is always *about* a
    specific article, and a create endpoint that took a unit id would be a
    second way in with its own chance to forget the write-off.
    """

    serializer_class = ConsignmentIncidentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_consignment_liability",),
        "retrieve": ("inventory.view_consignment_liability",),
        "assess": ("inventory.manage_consignmentincident",),
        "settle": ("inventory.disburse_consignment_payout",),
        "claims": ("inventory.view_consignment_liability",),
    }
    filterset_class = ConsignmentIncidentFilter
    ordering = ("-discovered_at", "-id")
    search_fields = (
        "number",
        "unit__code",
        "unit__consignor__full_name",
        "narrative",
    )

    def get_queryset(self):
        return (
            ConsignmentIncident.objects.select_related(
                "unit",
                "unit__variant",
                "unit__variant__product",
                "unit__consignor",
                "agreement",
                "reported_by",
            )
            .prefetch_related("unit__variant__option_values__option")
            .order_by(*self.ordering)
        )

    @action(detail=True, methods=["post"])
    def assess(self, request, pk=None):
        """Who is responsible, and what that comes to."""
        from . import custody

        serializer = AssessIncidentSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        incident = custody.assess_incident(
            self.get_object(),
            responsibility=serializer.validated_data["responsibility"],
            assessed_value=serializer.validated_data.get("assessed_value"),
            note=serializer.validated_data.get("note", ""),
            request=request,
        )
        return Response(
            self.get_serializer(self.get_queryset().get(pk=incident.pk)).data
        )

    @action(detail=True, methods=["post"])
    def settle(self, request, pk=None):
        """Close it — paid, replaced, waived, insured or no claim."""
        from . import custody

        serializer = SettleIncidentSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        incident = custody.settle_incident(
            self.get_object(),
            resolution=serializer.validated_data["resolution"],
            method=serializer.validated_data["method"],
            replacement_unit=serializer.validated_data.get("replacement_unit"),
            reference=serializer.validated_data.get("reference", ""),
            notes=serializer.validated_data.get("notes", ""),
            request=request,
        )
        return Response(
            self.get_serializer(self.get_queryset().get(pk=incident.pk)).data
        )

    @action(detail=False, methods=["get"])
    def claims(self, request):
        """The claims report: what is owed, what nobody has priced yet.

        Two figures and never one. An incident with an undetermined
        responsibility carries a zero nobody chose, and adding it to a total
        would say the shop had accepted a liability it has not.
        """
        return Response(
            {
                "open_value": figures.consignor_claims_open(),
                "unassessed_count": figures.consignor_claims_unassessed(),
                "open_count": figures.open_incidents().count(),
                "by_responsibility": {
                    row["responsibility"]: row["total"]
                    for row in figures.open_incidents()
                    .values("responsibility")
                    .annotate(total=Count("id"))
                },
            }
        )


class ConsignmentPositionView(APIView):
    """The four figures of §5.8, plus what the shop is holding for other people."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": ("inventory.view_consignment_liability",)}

    def get(self, request):
        from apps.core.money_dates import day_range_end, day_range_start
        from django.utils import timezone

        today = timezone.localdate()
        start = request.query_params.get("start")
        end = request.query_params.get("end")
        return Response(
            figures.consignment_position(
                start=day_range_start(start) if start else None,
                end=day_range_end(end) if end else None,
                as_of=day_range_end(end) if end else day_range_end(today),
            )
        )


class UnitAttributeDefinitionViewSet(viewsets.ModelViewSet):
    """Which typed facts each kind of article records.

    A deliberately narrow slice of custom fields — a used-goods trade cannot
    work without "battery health is a percentage and it sorts" — and explicitly
    not the beginning of a metadata engine.
    """

    serializer_class = UnitAttributeDefinitionSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("inventory.view_stockunit",),
        "retrieve": ("inventory.view_stockunit",),
        "create": ("inventory.manage_unitattributedefinition",),
        "update": ("inventory.manage_unitattributedefinition",),
        "partial_update": ("inventory.manage_unitattributedefinition",),
        "destroy": ("inventory.manage_unitattributedefinition",),
    }
    filterset_fields = ("asset_type", "data_type", "is_filterable")
    ordering = ("asset_type", "display_order", "id")

    def get_queryset(self):
        return UnitAttributeDefinition.objects.select_related("asset_type").order_by(
            *self.ordering
        )
