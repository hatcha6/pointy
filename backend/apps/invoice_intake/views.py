"""The intake API: start one, read it back, apply it, abandon it.

Permissions ride on purchasing's own codes rather than new ones for this model:
an intake is a purchase order in the making, and anybody who may create a
purchase order may create one from a photograph. The writes it eventually
performs are gated independently and for real — the products through
``catalog.add_product``, the submit/receive/pay steps through their own actions
— because the apply dispatches through those viewsets as the requesting user.
"""

from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from .models import InvoiceIntake
from .serializers import (
    InvoiceIntakeApplySerializer,
    InvoiceIntakeCreateSerializer,
    InvoiceIntakeSerializer,
)
from .services import apply_intake, cancel_intake, run_pipeline


class InvoiceIntakeViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = InvoiceIntakeSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("purchasing.view_purchaseorder",),
        "retrieve": ("purchasing.view_purchaseorder",),
        "create": ("purchasing.add_purchaseorder",),
        "apply": ("purchasing.add_purchaseorder",),
        "cancel": ("purchasing.add_purchaseorder",),
    }
    queryset = InvoiceIntake.objects.select_related(
        "supplier",
        "purchase_order",
        "created_by",
    ).prefetch_related("pages")
    filterset_fields = ("status", "source", "supplier", "purchase_order")
    ordering_fields = ("created_at", "status")

    def create(self, request, *args, **kwargs):
        payload = InvoiceIntakeCreateSerializer(data=request.data)
        payload.is_valid(raise_exception=True)
        data = payload.validated_data

        intake = InvoiceIntake.objects.create(
            created_by=request.user,
            source=data.get("source", InvoiceIntake.Source.CHAT),
            supplier=data.get("supplier"),
            review_edits=data.get("review_edits") or {},
            status=InvoiceIntake.Status.CAPTURING,
        )
        pages = data.get("pages") or []
        if pages:
            intake.pages.set(pages)
        if "extraction" in data:
            run_pipeline(
                intake,
                data["extraction"],
                user=request.user,
                supplier=data.get("supplier"),
            )
        intake.refresh_from_db()
        return Response(
            self.get_serializer(intake).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def apply(self, request, pk=None):
        """Create everything the (possibly edited) plan describes, in one
        transaction. Re-applying returns the purchase order already made."""
        intake = self.get_object()
        payload = InvoiceIntakeApplySerializer(data=request.data)
        payload.is_valid(raise_exception=True)
        options = payload.validated_data.get("options") or {}
        purchase_order = apply_intake(
            intake,
            payload.validated_data.get("plan"),
            user=request.user,
            options=options,
        )
        intake.refresh_from_db()
        data = self.get_serializer(intake).data
        data["purchase_order_id"] = purchase_order.pk
        return Response(data, status=status.HTTP_200_OK)

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        intake = cancel_intake(self.get_object())
        return Response(self.get_serializer(intake).data, status=status.HTTP_200_OK)
