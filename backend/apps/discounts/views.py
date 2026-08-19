from django.db.models import Count, IntegerField, OuterRef, Subquery
from django.db.models.functions import Coalesce
from django.utils import timezone
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.permissions import HasPointyPermission
from .analytics import discount_rule_beneficiaries, discount_rule_performance
from .models import AppliedDiscount, DiscountRedemption, DiscountRule
from .serializers import DiscountRuleSerializer


def _usage_count(model):
    """Count a rule's rows in ``model`` as an independent subquery.

    These two counts used to be ``Count("redemptions", distinct=True)`` and
    ``Count("applied_discounts", distinct=True)`` on the same ``annotate()``.
    Both are multi-valued reverse relations, so a single query LEFT JOINs them
    together and the database materialises the *cross product* — every
    redemption paired with every applied discount, per rule. ``distinct=True``
    corrects the number but not the work: rows scanned grow as
    redemptions x applied_discounts, and the GROUP BY runs over the whole table
    before pagination can trim it. ``AppliedDiscount`` gains a row for every
    discounted line ever sold, so that product only ever grows.

    A subquery per relation keeps each count an index scan on ``rule_id``, so
    the row count stays linear in the number of rules. The explicit
    ``order_by()`` drops the model's ``Meta.ordering`` from the grouped
    subquery, and ``Coalesce`` preserves the LEFT JOIN's 0 for a rule that has
    never been used.
    """
    return Coalesce(
        Subquery(
            model.objects.filter(rule=OuterRef("pk"))
            .order_by()
            .values("rule")
            .annotate(usage_count=Count("pk"))
            .values("usage_count")[:1],
            output_field=IntegerField(),
        ),
        0,
    )


class DiscountRuleViewSet(viewsets.ModelViewSet):
    serializer_class = DiscountRuleSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("discounts.view_discountrule",),
        "retrieve": ("discounts.view_discountrule",),
        "create": ("discounts.add_discountrule",),
        "update": ("discounts.change_discountrule",),
        "partial_update": ("discounts.change_discountrule",),
        "enable": ("discounts.change_discountrule",),
        "disable": ("discounts.change_discountrule",),
        "beneficiaries": ("discounts.view_discountrule",),
        "performance": ("discounts.view_discountrule",),
        "destroy": ("discounts.delete_discountrule",),
    }
    queryset = DiscountRule.objects.all()
    filterset_fields = (
        "channel",
        "application_type",
        "scope",
        "value_type",
        "is_active",
        "exclusive",
    )
    search_fields = ("name", "coupon_code", "description")
    ordering_fields = (
        "priority",
        "name",
        "starts_at",
        "ends_at",
        "created_at",
        "updated_at",
    )

    def get_queryset(self):
        return (
            super()
            .get_queryset()
            .prefetch_related(
                "products",
                "variants",
                "product_categories",
                "customers",
                "suppliers",
                "tiers",
            )
            .annotate(
                redemption_count=_usage_count(DiscountRedemption),
                applied_count=_usage_count(AppliedDiscount),
            )
        )

    def perform_create(self, serializer):
        rule = serializer.save()
        self._record_rule_event("discounts.rule.created", rule)

    def perform_update(self, serializer):
        changed_fields = sorted(serializer.validated_data.keys())
        rule = serializer.save()
        self._record_rule_event(
            "discounts.rule.updated",
            rule,
            extra_attributes={"changed_fields": changed_fields},
            extra_metrics={"changed_field_count": len(changed_fields)},
        )

    @action(detail=True, methods=["post"])
    def enable(self, request, pk=None):
        rule = self.get_object()
        rule.is_active = True
        rule.save(update_fields=["is_active", "updated_at"])
        self._record_rule_event("discounts.rule.enabled", rule)
        return Response(self.get_serializer(rule).data)

    @action(detail=True, methods=["post"])
    def disable(self, request, pk=None):
        rule = self.get_object()
        rule.is_active = False
        rule.save(update_fields=["is_active", "updated_at"])
        self._record_rule_event("discounts.rule.disabled", rule)
        return Response(self.get_serializer(rule).data)

    @action(detail=True, methods=["get"])
    def performance(self, request, pk=None):
        rule = self.get_object()
        return Response(discount_rule_performance(rule))

    @action(detail=True, methods=["get"])
    def beneficiaries(self, request, pk=None):
        rule = self.get_object()
        beneficiaries = discount_rule_beneficiaries(rule)
        page = self.paginate_queryset(beneficiaries)
        if page is not None:
            return self.get_paginated_response(page)
        return Response(beneficiaries)

    def perform_destroy(self, instance):
        metadata = dict(instance.metadata or {})
        metadata.setdefault("archived_at", timezone.now().isoformat())
        instance.metadata = metadata
        instance.is_active = False
        instance.save(update_fields=["is_active", "metadata", "updated_at"])
        self._record_rule_event(
            "discounts.rule.archived",
            instance,
            severity=AnalyticsEvent.Severity.WARNING,
        )

    def destroy(self, request, *args, **kwargs):
        instance = self.get_object()
        self.perform_destroy(instance)
        serializer = self.get_serializer(instance)
        return Response(serializer.data, status=status.HTTP_200_OK)

    def _record_rule_event(
        self,
        name,
        rule,
        *,
        severity=AnalyticsEvent.Severity.INFO,
        extra_attributes=None,
        extra_metrics=None,
    ):
        attributes = {
            "discount_rule_id": rule.pk,
            "discount_rule_name": rule.name,
            "channel": rule.channel,
            "application_type": rule.application_type,
            "coupon_code_present": bool(rule.coupon_code),
            "scope": rule.scope,
            "value_type": rule.value_type,
            "exclusive": rule.exclusive,
            "is_active": rule.is_active,
            "has_schedule": bool(rule.starts_at or rule.ends_at),
            "has_usage_limit": rule.usage_limit is not None,
            **(extra_attributes or {}),
        }
        metrics = {
            "value": float(rule.value),
            "priority": rule.priority,
            "constraint_count": self._constraint_count(rule),
            "redemption_count": getattr(rule, "redemption_count", 0) or 0,
            "applied_count": getattr(rule, "applied_count", 0) or 0,
            **(extra_metrics or {}),
        }
        record_domain_event(
            name=name,
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=severity,
            user=self.request.user,
            entity_type="discount_rule",
            entity_id=rule.pk,
            attributes=attributes,
            metrics=metrics,
        )

    def _constraint_count(self, rule):
        return (
            rule.products.count()
            + rule.variants.count()
            + rule.product_categories.count()
            + rule.customers.count()
            + rule.suppliers.count()
        )
