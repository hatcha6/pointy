"""API for rule-driven bulk repricing — see :mod:`apps.catalog.bulk_pricing`.

``POST bulk-price-changes/preview/`` plans a spec and returns its summary, one
page of rows and a fingerprint; ``POST bulk-price-changes/`` applies the same
spec only if it still produces that fingerprint; ``POST …/{id}/revert/`` undoes
an applied change. The list is the history.
"""

from __future__ import annotations

from decimal import Decimal

from rest_framework import mixins, serializers, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from . import bulk_pricing as bp
from . import bulk_pricing_data as data
from .models import BulkPriceChange

PREVIEW_VIEWS = ("all", "changed", "increased", "decreased", "unchanged", "warnings")
MAX_PAGE = 200


def _money(value):
    return None if value is None else str(value)


def _user_name(user):
    if user is None:
        return None
    return user.get_full_name().strip() or user.get_username()


class BulkPriceChangeSerializer(serializers.ModelSerializer):
    created_by_name = serializers.SerializerMethodField()
    reverted_by_name = serializers.SerializerMethodField()

    class Meta:
        model = BulkPriceChange
        fields = (
            "id",
            "created_at",
            "created_by_name",
            "spec",
            "summary",
            "reverted_at",
            "reverted_by_name",
            "revert_summary",
        )
        read_only_fields = fields

    def get_created_by_name(self, obj):
        return _user_name(obj.created_by)

    def get_reverted_by_name(self, obj):
        return _user_name(obj.reverted_by)


class BulkPriceChangeDetailSerializer(BulkPriceChangeSerializer):
    class Meta(BulkPriceChangeSerializer.Meta):
        fields = BulkPriceChangeSerializer.Meta.fields + ("changes",)
        read_only_fields = fields


def _row_payload(result: bp.RowResult, *, show_cost: bool) -> dict:
    row = result.row
    payload = {
        "variant_id": row.variant_id,
        "product_id": row.product_id,
        "product_name": row.product_name,
        "variant_name": row.variant_name if row.variant_name != row.product_name else "",
        "sku": row.sku,
        "old_price": _money(row.price),
        "new_price": _money(result.new_price),
        "delta": _money(result.delta),
        "delta_percent": _money(result.delta_percent),
        "applied_steps": list(result.applied),
        "flags": sorted(result.flags),
        "packs": [
            {
                "unit_id": pack.unit_id,
                "label": pack.label,
                "old_price": _money(pack.old_price),
                "new_price": _money(pack.new_price),
            }
            for pack in result.packs
        ],
    }
    if show_cost:
        old_markup = bp.markup_of(row.price, row.cost)
        new_markup = bp.markup_of(result.new_price, row.cost)
        payload.update(
            cost=_money(row.cost),
            old_markup=_money(None if old_markup is None else old_markup.quantize(Decimal("0.1"))),
            new_markup=_money(None if new_markup is None else new_markup.quantize(Decimal("0.1"))),
        )
    return payload


def _in_view(result: bp.RowResult, view: str) -> bool:
    if view == "changed":
        return result.changed
    if view == "increased":
        return result.new_price > result.row.price
    if view == "decreased":
        return result.new_price < result.row.price
    if view == "unchanged":
        return not result.changed
    if view == "warnings":
        return result.has_warning
    return True


def _int(raw, name, default, *, minimum, maximum):
    if raw in (None, ""):
        return default
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise ValidationError({name: ["Must be a whole number."]})
    return max(minimum, min(maximum, value))


class BulkPriceChangeViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    queryset = BulkPriceChange.objects.select_related("created_by", "reverted_by")
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.change_product",),
        "retrieve": ("catalog.change_product",),
        "options": ("catalog.change_product",),
        "preview": ("catalog.change_product",),
        "create": ("catalog.change_product",),
        "revert": ("catalog.change_product",),
    }

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.action == "list":
            return queryset.defer("changes")
        return queryset

    def get_serializer_class(self):
        if self.action == "retrieve":
            return BulkPriceChangeDetailSerializer
        return BulkPriceChangeSerializer

    @action(detail=False, methods=["get"])
    def options(self, request):
        return Response(
            {
                "cost_visible": data.cost_visible(request.user),
                "max_steps": bp.MAX_STEPS,
                "max_conditions": bp.MAX_CONDITIONS,
                "max_depth": bp.MAX_DEPTH,
                "big_change_percent": str(bp.BIG_CHANGE_PERCENT),
            }
        )

    @action(detail=False, methods=["post"])
    def preview(self, request):
        show_cost = data.cost_visible(request.user)
        spec = bp.parse_spec(request.data, cost_visible=show_cost)
        view = request.data.get("view") or "changed"
        if view not in PREVIEW_VIEWS:
            raise ValidationError({"view": ["Unknown view."]})
        offset = _int(request.data.get("offset"), "offset", 0, minimum=0, maximum=10**7)
        limit = _int(request.data.get("limit"), "limit", 50, minimum=1, maximum=MAX_PAGE)

        plan = data.build_plan(spec, show_cost=show_cost)
        rows = [result for result in plan.results if _in_view(result, view)]
        page = rows[offset : offset + limit]
        return Response(
            {
                "fingerprint": plan.fingerprint(),
                "summary": data._json_summary(plan.summary()),
                "cost_visible": show_cost,
                "view": view,
                "count": len(rows),
                "offset": offset,
                "rows": [_row_payload(result, show_cost=show_cost) for result in page],
            }
        )

    def create(self, request):
        show_cost = data.cost_visible(request.user)
        spec = bp.parse_spec(request.data, cost_visible=show_cost)
        fingerprint = request.data.get("fingerprint")
        if not isinstance(fingerprint, str) or not fingerprint:
            raise ValidationError({"fingerprint": ["Preview before applying."]})
        change = data.apply_spec(spec, fingerprint=fingerprint, user=request.user)
        return Response(BulkPriceChangeSerializer(change).data, status=201)

    @action(detail=True, methods=["post"])
    def revert(self, request, pk=None):
        change = self.get_object()
        change = data.revert_change(change.pk, user=request.user)
        return Response(BulkPriceChangeSerializer(change).data)
