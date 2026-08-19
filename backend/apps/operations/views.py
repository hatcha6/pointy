from django.contrib.auth import get_user_model
from django.db.models import Count, Prefetch
from django.db.models.deletion import ProtectedError
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.catalog.models import BillOfMaterials, VariantOptionValue
from apps.core.discovery import request_is_relayed
from apps.core.idempotency import run_idempotent_request
from apps.core.models import ShopSettings
from apps.core.permissions import HasPointyPermission
from apps.customers.models import Asset
from apps.employees.models import Employee
from apps.sales.models import RegisterSession
from apps.sales.views import register_session_owner_key
from .models import Job, JobAsset, WorkflowTemplate
from .serializers import (
    AssetSerializer,
    BillOfMaterialsSerializer,
    JobAssignSerializer,
    JobCreateSerializer,
    JobInvoiceSerializer,
    JobMaterialCreateSerializer,
    JobSerializer,
    JobTransitionSerializer,
    PublicJobSerializer,
    WorkflowTemplateSerializer,
)
from .services import (
    add_job_material,
    assign_job,
    cancel_job,
    create_job,
    explode_bom_into_job,
    invoice_job,
    reopen_job,
    reverse_job_material,
    transition_job,
)


class JobViewSet(
    mixins.CreateModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    mixins.ListModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = JobSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("operations.view_job",),
        "retrieve": ("operations.view_job",),
        "create": ("operations.add_job",),
        "update": ("operations.change_job",),
        "partial_update": ("operations.change_job",),
        "transition": ("operations.change_job",),
        "assign": ("operations.assign_job",),
        "add_material": ("operations.add_jobmaterial",),
        "reverse_material": ("operations.change_jobmaterial",),
        "cancel": ("operations.change_job",),
        "reopen": ("operations.reopen_job",),
        "invoice": (
            "operations.change_job",
            "sales.add_order",
            "payments.add_payment",
        ),
    }
    queryset = (
        Job.objects.select_related(
            "workflow_template",
            "current_stage",
            "customer",
            "assigned_to",
            "assigned_employee",
            "sales_channel",
            "order",
            "output_variant",
            "output_variant__product",
        )
        .prefetch_related(
            "workflow_template__stages",
            "job_assets__asset__customer",
            "materials__variant__product",
            # ``variant_name``/``output_variant_name`` read
            # ``ProductVariant.display_name``, which falls back to
            # ``option_values_label`` whenever the variant has no explicit name
            # (the common case for default variants). Un-prefetched that is one
            # query per material line, so a board of jobs with three parts each
            # cost three queries a row. Same shape as OrderViewSet's
            # ``lines__variant__option_values`` prefetch.
            Prefetch(
                "materials__variant__option_values",
                queryset=VariantOptionValue.objects.select_related("option"),
            ),
            Prefetch(
                "output_variant__option_values",
                queryset=VariantOptionValue.objects.select_related("option"),
            ),
            "stage_events__from_stage",
            "stage_events__to_stage",
            "stage_events__changed_by",
        )
    )
    filterset_fields = (
        "status",
        "job_type",
        "current_stage",
        "assigned_to",
        "customer",
        "workflow_template",
    )
    search_fields = (
        "job_number",
        "customer__full_name",
        "customer__phone",
        "job_assets__asset__imei",
        "job_assets__asset__serial_number",
        "symptoms",
    )
    ordering_fields = ("created_at", "updated_at", "due_at", "priority")

    def get_queryset(self):
        queryset = super().get_queryset()
        asset_id = self.request.query_params.get("asset")
        if asset_id:
            queryset = queryset.filter(job_assets__asset_id=asset_id).distinct()
        return queryset

    def create(self, request, *args, **kwargs):
        return run_idempotent_request(request, lambda: self._create(request))

    def _create(self, request):
        serializer = JobCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        assigned_to = None
        assigned_to_id = data.get("assigned_to_id")
        if assigned_to_id:
            assigned_to = get_user_model().objects.filter(pk=assigned_to_id).first()

        # Crediting an employee at intake also stamps the system user (when the
        # employee has a login) so the "assigned to me" board stays consistent.
        assigned_employee = data.get("assigned_employee")
        if assigned_employee is not None:
            assigned_to = assigned_employee.user

        bom = data.get("bom")
        batches = data.get("batches", 1)
        fields = {
            "customer": data.get("customer"),
            "assigned_to": assigned_to,
            "assigned_employee": assigned_employee,
            "priority": data["priority"],
            "due_at": data.get("due_at"),
            "symptoms": data.get("symptoms", ""),
            "quoted_price": data.get("quoted_price"),
            "warranty_days": data.get("warranty_days", 0),
        }
        if bom is not None:
            fields.update(
                bom=bom,
                output_variant=bom.variant,
                output_quantity=bom.output_quantity * batches,
            )

        job = create_job(
            workflow_template=data["workflow_template"],
            request=request,
            **fields,
        )
        for asset in data.get("asset_ids") or []:
            JobAsset.objects.create(job=job, asset=asset)
        if bom is not None:
            explode_bom_into_job(job=job, bom=bom, batches=batches)

        job = self.get_queryset().get(pk=job.pk)
        return Response(
            JobSerializer(job, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def transition(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._transition(request))

    def _transition(self, request):
        job = self.get_object()
        serializer = JobTransitionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        transition_job(
            job=job,
            to_stage=serializer.validated_data["to_stage"],
            request=request,
            note=serializer.validated_data.get("note", ""),
        )
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def assign(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._assign(request))

    def _assign(self, request):
        job = self.get_object()
        serializer = JobAssignSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        assign_job(
            job=job,
            employee=serializer.validated_data.get("employee"),
            request=request,
        )
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"], url_path="materials")
    def add_material(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._add_material(request))

    def _add_material(self, request):
        job = self.get_object()
        serializer = JobMaterialCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        add_job_material(
            job=job,
            variant=serializer.validated_data["variant"],
            quantity=serializer.validated_data["quantity"],
            consume_now=serializer.validated_data["consume_now"],
            request=request,
        )
        return self._refreshed(request, job.pk)

    @action(
        detail=True,
        methods=["post"],
        url_path="materials/(?P<material_id>[0-9]+)/reverse",
    )
    def reverse_material(self, request, pk=None, material_id=None):
        job = self.get_object()
        material = job.materials.filter(pk=material_id).first()
        if material is None:
            return Response(
                {"detail": "Material not found on this job."},
                status=status.HTTP_404_NOT_FOUND,
            )
        reverse_job_material(job=job, material=material, request=request)
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        job = self.get_object()
        cancel_job(job=job, request=request, reason=str(request.data.get("reason", "")))
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def reopen(self, request, pk=None):
        job = self.get_object()
        reopen_job(job=job, request=request, note=str(request.data.get("note", "")))
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def invoice(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._invoice(request))

    def _invoice(self, request):
        job = self.get_object()
        serializer = JobInvoiceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        session = RegisterSession.objects.filter(
            owner_key=register_session_owner_key(request),
            status=RegisterSession.Status.OPEN,
        ).first()
        if session is None:
            return Response(
                {"detail": "No open register session for this request owner."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        invoice_job(
            job=job,
            register_session=session,
            payments_data=serializer.validated_data["payments"],
            labor_total=serializer.validated_data.get("labor_total"),
            request=request,
        )
        return self._refreshed(request, job.pk)

    def _refreshed(self, request, job_id):
        job = self.get_queryset().get(pk=job_id)
        return Response(JobSerializer(job, context={"request": request}).data)


class AssetViewSet(viewsets.ModelViewSet):
    serializer_class = AssetSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("customers.view_asset",),
        "retrieve": ("customers.view_asset",),
        "create": ("customers.add_asset",),
        "update": ("customers.change_asset",),
        "partial_update": ("customers.change_asset",),
        "destroy": ("customers.delete_asset",),
    }
    queryset = Asset.objects.select_related("customer").annotate(
        job_count=Count("job_links"),
    )
    filterset_fields = ("customer", "asset_type", "is_active")
    search_fields = ("brand", "model_name", "serial_number", "imei")

    def destroy(self, request, *args, **kwargs):
        try:
            return super().destroy(request, *args, **kwargs)
        except ProtectedError:
            return Response(
                {"detail": "This item has job history and cannot be deleted."},
                status=status.HTTP_409_CONFLICT,
            )


class WorkflowTemplateViewSet(viewsets.ModelViewSet):
    serializer_class = WorkflowTemplateSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("operations.view_workflowtemplate",),
        "retrieve": ("operations.view_workflowtemplate",),
        "create": ("operations.add_workflowtemplate",),
        "update": ("operations.change_workflowtemplate",),
        "partial_update": ("operations.change_workflowtemplate",),
        "destroy": ("operations.delete_workflowtemplate",),
    }
    queryset = (
        WorkflowTemplate.objects.prefetch_related("stages")
        .annotate(job_count=Count("jobs"))
        .order_by("job_type", "name")
    )
    filterset_fields = ("job_type", "is_active")

    def destroy(self, request, *args, **kwargs):
        template = self.get_object()
        if template.is_system:
            return Response(
                {"detail": "Built-in workflows cannot be deleted; disable instead."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            return super().destroy(request, *args, **kwargs)
        except ProtectedError:
            return Response(
                {"detail": "This workflow has jobs and cannot be deleted."},
                status=status.HTTP_409_CONFLICT,
            )


class BillOfMaterialsViewSet(viewsets.ModelViewSet):
    serializer_class = BillOfMaterialsSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("catalog.view_billofmaterials",),
        "retrieve": ("catalog.view_billofmaterials",),
        "create": ("catalog.add_billofmaterials",),
        "update": ("catalog.change_billofmaterials",),
        "partial_update": ("catalog.change_billofmaterials",),
        "destroy": ("catalog.delete_billofmaterials",),
    }
    queryset = BillOfMaterials.objects.select_related(
        "variant",
        "variant__product",
    ).prefetch_related("lines__component_variant__product")
    filterset_fields = ("variant", "is_active")
    search_fields = ("name", "variant__product__name")

    def destroy(self, request, *args, **kwargs):
        try:
            return super().destroy(request, *args, **kwargs)
        except ProtectedError:
            return Response(
                {"detail": "This recipe is used by jobs and cannot be deleted."},
                status=status.HTTP_409_CONFLICT,
            )


class PublicJobView(mixins.RetrieveModelMixin, viewsets.GenericViewSet):
    """Customer-facing job tracking, mirroring the public invoice page."""

    serializer_class = PublicJobSerializer
    permission_classes = [AllowAny]
    authentication_classes = []
    lookup_field = "public_token"
    lookup_url_kwarg = "token"
    queryset = Job.objects.select_related("current_stage")

    def get_queryset(self):
        if not request_is_relayed(self.request):
            return Job.objects.none()
        if not ShopSettings.load().enable_job_tracking:
            return Job.objects.none()
        return super().get_queryset()
