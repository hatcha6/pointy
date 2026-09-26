from django.contrib.auth import get_user_model
from django.db.models import Count, F, Max, Prefetch, Q
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
from apps.customers.models import Asset, AssetOwnership, AssetType
from apps.employees.models import Employee
from apps.sales.models import RegisterSession
from apps.sales.views import register_session_owner_key
from .models import Job, JobAsset, WorkflowTemplate
from .serializers import (
    AssetDetailSerializer,
    AssetSerializer,
    AssetTransferSerializer,
    AssetTypeSerializer,
    BillOfMaterialsSerializer,
    JobAssigneeSerializer,
    JobAssignSerializer,
    JobCreateSerializer,
    JobDeclineSerializer,
    JobDetailSerializer,
    JobHandBackSerializer,
    JobHoldSerializer,
    JobInvoiceSerializer,
    JobMaterialCreateSerializer,
    JobSerializer,
    JobServiceCreateSerializer,
    JobTransitionSerializer,
    PublicJobSerializer,
    WorkflowTemplateSerializer,
)
from apps.customers.services import transfer_asset
from .services import (
    add_job_material,
    add_job_service,
    assign_job,
    awaiting_hand_back_q,
    cancel_job,
    create_job,
    decline_job,
    explode_bom_into_job,
    hand_back_declined_job,
    hold_job,
    invoice_job,
    remove_job_service,
    reopen_job,
    resume_job,
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
        # Whoever assigns work picks from this list, so it rides the same
        # permission rather than the HR one the employees endpoint needs.
        "assignees": ("operations.assign_job",),
        "add_material": ("operations.add_jobmaterial",),
        # Putting a part back is the undo of fitting it: whoever may add parts
        # may take back the one they fitted by mistake. The grantable
        # "manage job materials" permission is add_jobmaterial alone, and a
        # reverse button that 403s for the people it is offered to is worse
        # than none.
        "reverse_material": ("operations.add_jobmaterial",),
        "add_service": ("operations.change_job",),
        "remove_service": ("operations.change_job",),
        "hold": ("operations.change_job",),
        "resume": ("operations.change_job",),
        "cancel": ("operations.change_job",),
        "decline": ("operations.change_job",),
        "hand_back": ("operations.change_job",),
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
            "created_by",
            "cancelled_by",
            "sales_channel",
            "order",
            "output_variant",
            "output_variant__product",
        )
        .prefetch_related(
            "workflow_template__stages",
            # ``settlement_state`` / ``order_amount_paid`` sum the order's
            # payments in Python (Order.amount_paid does, deliberately, so a
            # prefetch is reused). Un-prefetched that is a query per row on the
            # board — the exact shape the job-list scaling test guards.
            "order__payments",
            # ``order_balance_due`` also counts what came back (returns).
            "order__adjustments",
            # A part's ``is_billed`` pairs it with its invoice line and asks how
            # much of that line came back (``invoice_returns.billed_parts``).
            "order__lines__variant__product",
            "order__lines__adjustment_lines",
            "job_assets__asset__customer",
            "materials__variant__product",
            "services__variant__product",
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
            # Service lines read ``display_name`` too, and fall back to
            # ``option_values_label`` the same way — so without this a board of
            # invoiced jobs paid one query per service line, exactly the N+1 the
            # materials prefetch above exists to stop.
            Prefetch(
                "services__variant__option_values",
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

    def get_serializer_class(self):
        # A single job carries its whole workflow, so the job screen can move it
        # to any stage; the board's list does not repeat it on every card.
        if self.action in ("retrieve", "update", "partial_update"):
            return JobDetailSerializer
        return super().get_serializer_class()

    def get_queryset(self):
        queryset = super().get_queryset()
        asset_id = self.request.query_params.get("asset")
        if asset_id:
            queryset = queryset.filter(job_assets__asset_id=asset_id).distinct()
        # The shelf the board cannot show: declined jobs whose item is still
        # here, waiting for the customer to collect it unrepaired.
        if self.request.query_params.get("awaiting_hand_back") in ("true", "1"):
            queryset = queryset.filter(awaiting_hand_back_q())
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
            JobDetailSerializer(job, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=False, methods=["get"])
    def assignees(self, request):
        """The people a job can be given to: active employees, by name."""
        employees = Employee.objects.filter(status=Employee.Status.ACTIVE).order_by(
            "full_name", "employee_number"
        )
        return Response(JobAssigneeSerializer(employees, many=True).data)

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
            handed_over_to=serializer.validated_data.get("handed_over_to", ""),
            force_release=serializer.validated_data.get("force_release", False),
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

    @action(detail=True, methods=["post"], url_path="services")
    def add_service(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._add_service(request))

    def _add_service(self, request):
        job = self.get_object()
        serializer = JobServiceCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        add_job_service(
            job=job,
            variant=serializer.validated_data.get("variant"),
            quantity=serializer.validated_data.get("quantity"),
            note=serializer.validated_data.get("note", ""),
            unit_price=serializer.validated_data.get("unit_price"),
            request=request,
        )
        return self._refreshed(request, job.pk)

    @action(
        detail=True,
        methods=["delete"],
        url_path="services/(?P<service_id>[0-9]+)",
    )
    def remove_service(self, request, pk=None, service_id=None):
        job = self.get_object()
        service = job.services.filter(pk=service_id).first()
        if service is None:
            return Response(
                {"detail": "Service not found on this job."},
                status=status.HTTP_404_NOT_FOUND,
            )
        remove_job_service(job=job, service=service, request=request)
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def hold(self, request, pk=None):
        job = self.get_object()
        serializer = JobHoldSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        hold_job(job=job, reason=serializer.validated_data["reason"], request=request)
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def resume(self, request, pk=None):
        job = self.get_object()
        resume_job(job=job, request=request)
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        job = self.get_object()
        cancel_job(job=job, request=request, reason=str(request.data.get("reason", "")))
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"])
    def decline(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._decline(request))

    def _decline(self, request):
        job = self.get_object()
        serializer = JobDeclineSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        decline_job(
            job=job,
            reason=serializer.validated_data["reason"],
            note=serializer.validated_data.get("note", ""),
            fee=serializer.validated_data.get("fee"),
            request=request,
        )
        return self._refreshed(request, job.pk)

    @action(detail=True, methods=["post"], url_path="hand-back")
    def hand_back(self, request, pk=None):
        return run_idempotent_request(request, lambda: self._hand_back(request))

    def _hand_back(self, request):
        job = self.get_object()
        serializer = JobHandBackSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        hand_back_declined_job(
            job=job,
            handed_over_to=serializer.validated_data.get("handed_over_to", ""),
            note=serializer.validated_data.get("note", ""),
            force_release=serializer.validated_data.get("force_release", False),
            request=request,
        )
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
            sale_type=serializer.validated_data.get("sale_type"),
            valid_until=serializer.validated_data.get("valid_until"),
            acknowledge_over_quote=serializer.validated_data.get(
                "acknowledge_over_quote",
                False,
            ),
        )
        return self._refreshed(request, job.pk)

    def _refreshed(self, request, job_id):
        job = self.get_queryset().get(pk=job_id)
        return Response(JobDetailSerializer(job, context={"request": request}).data)


class AssetViewSet(viewsets.ModelViewSet):
    """The registry of customer property the shop works on.

    A repair counter's first move is a lookup: a chassis number, a plate, an
    IMEI, a serial. One search box answers all four, and the answer carries the
    item's whole history — including work done for a previous owner, which is
    exactly why the registry is keyed on the item and not on the customer.
    """

    serializer_class = AssetSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("customers.view_asset",),
        "retrieve": ("customers.view_asset",),
        "create": ("customers.add_asset",),
        "update": ("customers.change_asset",),
        "partial_update": ("customers.change_asset",),
        "destroy": ("customers.delete_asset",),
        "transfer": ("customers.change_asset",),
    }
    queryset = Asset.objects.select_related("customer", "asset_type").annotate(
        job_count=Count("job_links", distinct=True),
        # "Is it in the shop right now?" An open job holds the item, and so
        # does a declined one until the customer collects it unrepaired.
        open_job_count=Count(
            "job_links",
            filter=Q(job_links__job__status=Job.Status.OPEN)
            | awaiting_hand_back_q("job_links__job__"),
            distinct=True,
        ),
        last_job_at=Max("job_links__job__created_at"),
    )
    filterset_fields = ("customer", "asset_type", "is_active")
    search_fields = (
        "brand",
        "model_name",
        "serial_number",
        "imei",
        "vin",
        "plate_number",
        "engine_number",
        # Whatever this trade calls its own number — a frame number, a meter
        # number — has to be findable by the same one search box.
        "custom_identifier",
    )
    ordering_fields = ("created_at", "last_job_at")

    def get_serializer_class(self):
        if self.action == "retrieve":
            return AssetDetailSerializer
        return AssetSerializer

    def get_queryset(self):
        # Aggregating clears the model's implicit Meta ordering (a GROUP BY
        # drops it), which leaves pagination free to repeat or skip rows between
        # pages. Order explicitly: most-recently-serviced first, since the
        # counter is nearly always asking about something that was here lately,
        # with never-serviced items last rather than first — where a plain DESC
        # would put their NULLs on Postgres. ``-id`` breaks ties so a page
        # boundary is stable. An explicit ``?ordering=`` still overrides this.
        queryset = super().get_queryset().order_by(
            F("last_job_at").desc(nulls_last=True),
            "-id",
        )
        # "What is in the shop right now?" — the wall-board question. An item is
        # in the shop while any job on it is still open.
        in_shop = self.request.query_params.get("in_shop")
        if in_shop in ("true", "1"):
            queryset = queryset.filter(open_job_count__gt=0)
        elif in_shop in ("false", "0"):
            queryset = queryset.filter(open_job_count=0)
        if self.action == "retrieve":
            queryset = queryset.prefetch_related(
                Prefetch(
                    "ownerships",
                    queryset=AssetOwnership.objects.select_related("customer"),
                ),
                Prefetch(
                    "job_links",
                    queryset=JobAsset.objects.select_related(
                        "job",
                        "job__current_stage",
                        "job__customer",
                        "job__order",
                    ).order_by("-job__created_at"),
                ),
            )
        return queryset

    @action(detail=True, methods=["post"])
    def transfer(self, request, pk=None):
        """Move an item to a new owner, keeping its service history with it."""
        asset = self.get_object()
        serializer = AssetTransferSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        transfer_asset(
            asset=asset,
            customer=serializer.validated_data["customer"],
            note=serializer.validated_data.get("note", ""),
            request=request,
        )
        refreshed = self.get_queryset().get(pk=asset.pk)
        return Response(
            AssetSerializer(refreshed, context={"request": request}).data
        )

    def destroy(self, request, *args, **kwargs):
        try:
            return super().destroy(request, *args, **kwargs)
        except ProtectedError:
            return Response(
                {"detail": "This item has job history and cannot be deleted."},
                status=status.HTTP_409_CONFLICT,
            )


class AssetTypeViewSet(viewsets.ModelViewSet):
    """The kinds of thing this shop works on.

    Readable by anyone who can see assets — the intake form needs the list and
    its ``tracks_*`` flags to know which identity fields to ask for — and
    editable only by someone who can change them.
    """

    serializer_class = AssetTypeSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("customers.view_asset",),
        "retrieve": ("customers.view_asset",),
        "create": ("customers.change_asset",),
        "update": ("customers.change_asset",),
        "partial_update": ("customers.change_asset",),
        "destroy": ("customers.change_asset",),
    }
    queryset = AssetType.objects.annotate(asset_count=Count("assets"))
    filterset_fields = ("is_active",)
    search_fields = ("name", "slug")
    ordering = ("display_order", "name")

    def destroy(self, request, *args, **kwargs):
        asset_type = self.get_object()
        if asset_type.is_system:
            # Same rule the seeded workflows use: a shop can turn a built-in
            # type off, but cannot delete its way to a registry with no types.
            return Response(
                {"detail": "Built-in types can be deactivated, not deleted."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            return super().destroy(request, *args, **kwargs)
        except ProtectedError:
            return Response(
                {"detail": "This type has items registered to it."},
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
    ).prefetch_related(
        "lines__component_variant__product",
        # ``variant_name``/``component_name`` read ``ProductVariant.display_name``,
        # which falls back to ``option_values_label`` whenever the variant has no
        # explicit name (the common case for default variants). Un-prefetched
        # that is one query for the output variant plus one per component line,
        # so a page of recipes cost (1 + lines) queries a row. Same shape as the
        # job board's ``materials__variant__option_values`` prefetch above.
        Prefetch(
            "variant__option_values",
            queryset=VariantOptionValue.objects.select_related("option"),
        ),
        Prefetch(
            "lines__component_variant__option_values",
            queryset=VariantOptionValue.objects.select_related("option"),
        ),
    )
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
