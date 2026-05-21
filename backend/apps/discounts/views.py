from django.db.models import Count
from django.utils import timezone
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission
from .models import DiscountRule
from .serializers import DiscountRuleSerializer


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
            )
            .annotate(
                redemption_count=Count("redemptions", distinct=True),
                applied_count=Count("applied_discounts", distinct=True),
            )
        )

    @action(detail=True, methods=["post"])
    def enable(self, request, pk=None):
        rule = self.get_object()
        rule.is_active = True
        rule.save(update_fields=["is_active", "updated_at"])
        return Response(self.get_serializer(rule).data)

    @action(detail=True, methods=["post"])
    def disable(self, request, pk=None):
        rule = self.get_object()
        rule.is_active = False
        rule.save(update_fields=["is_active", "updated_at"])
        return Response(self.get_serializer(rule).data)

    def perform_destroy(self, instance):
        metadata = dict(instance.metadata or {})
        metadata.setdefault("archived_at", timezone.now().isoformat())
        instance.metadata = metadata
        instance.is_active = False
        instance.save(update_fields=["is_active", "metadata", "updated_at"])

    def destroy(self, request, *args, **kwargs):
        instance = self.get_object()
        self.perform_destroy(instance)
        serializer = self.get_serializer(instance)
        return Response(serializer.data, status=status.HTTP_200_OK)
