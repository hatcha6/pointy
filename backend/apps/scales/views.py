from django.http import HttpResponse
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.catalog.models import ProductVariant, ScalePlu
from apps.core.permissions import HasPointyPermission

from . import services
from .drivers import ScaleError, build_driver
from .models import Scale, ScalePushJob
from .serializers import (
    ScaleDriverSerializer,
    ScalePluSerializer,
    ScalePushJobSerializer,
    ScaleSerializer,
)


class ScaleViewSet(viewsets.ModelViewSet):
    """The shop's scales, and the one button that matters: push."""

    serializer_class = ScaleSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("scales.view_scale",),
        "retrieve": ("scales.view_scale",),
        "create": ("scales.add_scale",),
        "update": ("scales.change_scale",),
        "partial_update": ("scales.change_scale",),
        "destroy": ("scales.delete_scale",),
        "drivers": ("scales.view_scale",),
        "check": ("scales.change_scale",),
        "push": ("scales.push_scale",),
        "export": ("scales.push_scale",),
        "pushes": ("scales.view_scale",),
    }
    queryset = Scale.objects.all()
    filterset_fields = ("is_active", "driver")

    @action(detail=False, methods=["get"])
    def drivers(self, request):
        return Response(ScaleDriverSerializer.catalog())

    @action(detail=True, methods=["post"])
    def check(self, request, pk=None):
        """Is the scale there? Answered before a shop waits on a whole push."""

        scale = self.get_object()
        try:
            build_driver(scale).check()
        except ScaleError as error:
            return Response(
                {"reachable": False, "detail": str(error)},
                status=status.HTTP_200_OK,
            )
        return Response({"reachable": True, "detail": ""})

    @action(detail=True, methods=["post"])
    def push(self, request, pk=None):
        scale = self.get_object()
        job = services.push_scale(scale, user=request.user)
        return Response(ScalePushJobSerializer(job).data)

    @action(detail=True, methods=["get"])
    def export(self, request, pk=None):
        """The PLU file, for a scale that is loaded from a USB stick."""

        scale = self.get_object()
        try:
            filename, content, record_count = services.export_plu_file(scale)
        except ScaleError as error:
            return Response(
                {"detail": str(error)}, status=status.HTTP_400_BAD_REQUEST
            )
        if record_count == 0:
            # An empty file loaded into a scale is indistinguishable from one
            # that never arrived. Say why instead of downloading nothing.
            return Response(
                {"detail": "No products are assigned to a PLU yet."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        # The driver decides the encoding — a vendor tool that wants cp1256 gets
        # cp1256 — so the header has to follow it rather than assert UTF-8.
        charset = str((scale.options or {}).get("encoding") or "utf-8-sig")
        response = HttpResponse(content, content_type=f"text/csv; charset={charset}")
        response["Content-Disposition"] = f'attachment; filename="{filename}"'
        return response

    @action(detail=True, methods=["get"])
    def pushes(self, request, pk=None):
        scale = self.get_object()
        jobs = ScalePushJob.objects.filter(scale=scale)[:20]
        return Response(ScalePushJobSerializer(jobs, many=True).data)


class ScalePluViewSet(viewsets.ModelViewSet):
    """Which products live on the scales, and what they print.

    Create takes a variant and allocates the number; it is never supplied by the
    caller, so a number that is already on a printed sticker cannot be handed to
    a second product.
    """

    serializer_class = ScalePluSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("scales.view_scale",),
        "retrieve": ("scales.view_scale",),
        "create": ("catalog.change_product",),
        "update": ("catalog.change_product",),
        "partial_update": ("catalog.change_product",),
        "destroy": ("catalog.change_product",),
    }
    queryset = ScalePlu.objects.select_related("variant__product").all()
    filterset_fields = ("is_active", "variant")

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        variant = serializer.validated_data["variant"]
        if not isinstance(variant, ProductVariant):
            variant = ProductVariant.objects.get(pk=variant)
        plu = services.allocate_plu(
            variant,
            label_name=serializer.validated_data.get("label_name", ""),
            tare_grams=serializer.validated_data.get("tare_grams", 0),
            shelf_life_days=serializer.validated_data.get("shelf_life_days"),
        )
        return Response(
            self.get_serializer(plu).data, status=status.HTTP_201_CREATED
        )
