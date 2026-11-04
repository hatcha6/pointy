"""``/api/bulk-tracking-changes/``: preview, then apply in batches."""

from __future__ import annotations

from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from . import bulk_tracking

MAX_BATCH = 200


class BulkTrackingChangeViewSet(viewsets.ViewSet):
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "preview": ("catalog.change_product", "catalog.change_productvariant"),
        "apply": ("catalog.change_product", "catalog.change_productvariant"),
    }

    @action(detail=False, methods=["post"])
    def preview(self, request):
        return Response(bulk_tracking.build_preview(request.data, user=request.user))

    @action(detail=False, methods=["post"])
    def apply(self, request):
        ids = request.data.get("product_ids")
        if (
            not isinstance(ids, list)
            or not ids
            or len(ids) > MAX_BATCH
            or not all(isinstance(pk, int) for pk in ids)
        ):
            raise ValidationError({"product_ids": [f"1 to {MAX_BATCH} product ids."]})
        return Response(
            bulk_tracking.apply_batch(request.data, user=request.user, product_ids=ids)
        )
