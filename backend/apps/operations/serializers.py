from decimal import Decimal

from django.db.models.deletion import ProtectedError
from rest_framework import serializers

from apps.catalog.models import BillOfMaterials, BomLine, ProductVariant
from apps.customers.models import Asset, AssetOwnership, AssetType, Customer
from apps.employees.models import Employee
from .models import (
    Job,
    JobAsset,
    JobMaterial,
    JobService,
    JobStageEvent,
    WorkflowStage,
    WorkflowTemplate,
)


class AssetTypeSerializer(serializers.ModelSerializer):
    """A kind of thing this shop works on, and which numbers it is identified by.

    The ``tracks_*`` flags drive the intake form: they are the reason a
    television is never asked for a number plate.
    """

    asset_count = serializers.IntegerField(read_only=True, default=0)

    class Meta:
        model = AssetType
        fields = [
            "id",
            "name",
            "slug",
            "icon_key",
            "display_order",
            "is_active",
            "is_system",
            "asset_count",
            "tracks_serial_number",
            "tracks_imei",
            "tracks_vin",
            "tracks_plate_number",
            "tracks_engine_number",
            "tracks_model_year",
            "tracks_odometer",
            "custom_identifier_label",
        ]
        read_only_fields = ("is_system",)

    def validate_slug(self, value):
        return value.strip()


class AssetOwnershipSerializer(serializers.ModelSerializer):
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)
    customer_phone = serializers.CharField(source="customer.phone", read_only=True)
    is_current = serializers.BooleanField(read_only=True)

    class Meta:
        model = AssetOwnership
        fields = [
            "id",
            "customer",
            "customer_name",
            "customer_phone",
            "acquired_at",
            "released_at",
            "is_current",
            "note",
        ]


class AssetSerializer(serializers.ModelSerializer):
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)
    customer_phone = serializers.CharField(source="customer.phone", read_only=True)
    display_name = serializers.CharField(read_only=True)
    identity_label = serializers.CharField(read_only=True)
    asset_type_name = serializers.CharField(source="asset_type.name", read_only=True)
    asset_type_slug = serializers.CharField(source="asset_type.slug", read_only=True)
    asset_type_icon = serializers.CharField(
        source="asset_type.icon_key", read_only=True
    )
    custom_identifier_label = serializers.CharField(
        source="asset_type.custom_identifier_label",
        read_only=True,
        default="",
    )
    job_count = serializers.IntegerField(read_only=True, default=0)
    # Annotated by the viewset: how many jobs on this item are still open, i.e.
    # "is this phone/car in the shop right now?".
    open_job_count = serializers.IntegerField(read_only=True, default=0)
    last_job_at = serializers.DateTimeField(read_only=True, default=None)

    class Meta:
        model = Asset
        fields = [
            "id",
            "customer",
            "customer_name",
            "customer_phone",
            "asset_type",
            "asset_type_name",
            "asset_type_slug",
            "asset_type_icon",
            "brand",
            "model_name",
            "serial_number",
            "imei",
            "vin",
            "plate_number",
            "engine_number",
            "custom_identifier",
            "custom_identifier_label",
            "model_year",
            "odometer",
            "color",
            "notes",
            "display_name",
            "identity_label",
            "job_count",
            "open_job_count",
            "last_job_at",
            "is_active",
            "created_at",
            "updated_at",
        ]


class AssetJobHistorySerializer(serializers.Serializer):
    """One visit in an item's service history.

    Deliberately not ``JobSerializer``: this is read from the asset's side, so
    it carries what a person asks about a past repair — when, what was wrong,
    what was done, what it cost — and none of the board's workflow machinery.
    """

    id = serializers.IntegerField(read_only=True)
    job_number = serializers.CharField(read_only=True)
    job_type = serializers.CharField(read_only=True)
    status = serializers.CharField(read_only=True)
    stage_name = serializers.CharField(source="current_stage.name", read_only=True)
    customer = serializers.IntegerField(source="customer_id", read_only=True)
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)
    symptoms = serializers.CharField(read_only=True)
    diagnosis = serializers.CharField(read_only=True)
    warranty_days = serializers.IntegerField(read_only=True)
    warranty_expires_on = serializers.DateField(read_only=True)
    is_under_warranty = serializers.BooleanField(read_only=True)
    created_at = serializers.DateTimeField(read_only=True)
    completed_at = serializers.DateTimeField(read_only=True)
    handed_over_at = serializers.DateTimeField(read_only=True)
    order_receipt_number = serializers.CharField(
        source="order.receipt_number",
        read_only=True,
        default="",
    )
    total = serializers.SerializerMethodField()

    def get_total(self, job) -> str | None:
        return str(job.order.total) if job.order_id else None


class AssetDetailSerializer(AssetSerializer):
    ownerships = AssetOwnershipSerializer(many=True, read_only=True)
    jobs = serializers.SerializerMethodField()
    total_spent = serializers.SerializerMethodField()
    warranty_expires_on = serializers.SerializerMethodField()

    class Meta(AssetSerializer.Meta):
        fields = AssetSerializer.Meta.fields + [
            "ownerships",
            "jobs",
            "total_spent",
            "warranty_expires_on",
        ]

    def get_warranty_expires_on(self, asset) -> str | None:
        """When this item's cover runs out, across every repair it has had.

        The first question at a repair counter when a customer walks back in is
        "is this still under your warranty?", and the answer is the latest cover
        any past repair gave — not the latest repair, which may have carried
        none. Modelled on ERPNext's Serial No ``maintenance_status``, but hung
        off the work rather than off a stock serial: the cover a shop gives is
        on what it did, not on the thing.
        """
        expiries = [
            job.warranty_expires_on
            for job in self._jobs(asset)
            if job.warranty_expires_on is not None
        ]
        return max(expiries).isoformat() if expiries else None

    def _jobs(self, asset):
        return [link.job for link in asset.job_links.all()]

    def get_jobs(self, asset):
        return AssetJobHistorySerializer(self._jobs(asset), many=True).data

    def get_total_spent(self, asset) -> str:
        total = sum(
            (job.order.total for job in self._jobs(asset) if job.order_id),
            Decimal("0.00"),
        )
        return str(total.quantize(Decimal("0.01")))


class AssetTransferSerializer(serializers.Serializer):
    customer = serializers.PrimaryKeyRelatedField(queryset=Customer.objects.all())
    note = serializers.CharField(
        required=False,
        allow_blank=True,
        default="",
        max_length=200,
    )


class WorkflowStageSerializer(serializers.ModelSerializer):
    id = serializers.IntegerField(required=False)

    class Meta:
        model = WorkflowStage
        fields = [
            "id",
            "code",
            "name",
            "display_order",
            "is_initial",
            "is_terminal",
            "requires_customer_approval",
            "requires_settlement",
            "releases_custody",
            "consumes_materials",
            "produces_output",
        ]


class WorkflowTemplateSerializer(serializers.ModelSerializer):
    stages = WorkflowStageSerializer(many=True)
    job_count = serializers.IntegerField(read_only=True, default=0)

    class Meta:
        model = WorkflowTemplate
        fields = [
            "id",
            "name",
            "job_type",
            "is_active",
            "is_system",
            "job_count",
            "stages",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("is_system",)

    def validate_stages(self, stages):
        if not stages:
            raise serializers.ValidationError("Workflow needs at least one stage.")
        initial_count = sum(1 for stage in stages if stage.get("is_initial"))
        if initial_count != 1:
            raise serializers.ValidationError(
                "Workflow needs exactly one starting stage."
            )
        if not any(stage.get("is_terminal") for stage in stages):
            raise serializers.ValidationError("Workflow needs a final stage.")
        codes = [stage.get("code") for stage in stages]
        if len(set(codes)) != len(codes):
            raise serializers.ValidationError("Stage codes must be unique.")
        return stages

    def create(self, validated_data):
        stages = validated_data.pop("stages")
        template = WorkflowTemplate.objects.create(**validated_data)
        self._sync_stages(template, stages)
        return template

    def update(self, instance, validated_data):
        stages = validated_data.pop("stages", None)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        if stages is not None:
            self._sync_stages(instance, stages)
        return instance

    def _sync_stages(self, template, stages):
        existing = {stage.pk: stage for stage in template.stages.all()}
        seen = set()
        for order, stage_data in enumerate(stages):
            stage_id = stage_data.pop("id", None)
            stage_data["display_order"] = order
            if stage_id and stage_id in existing:
                stage = existing[stage_id]
                for field, value in stage_data.items():
                    setattr(stage, field, value)
                stage.save()
                seen.add(stage_id)
            else:
                stage = WorkflowStage.objects.create(template=template, **stage_data)
        for stage_id, stage in existing.items():
            if stage_id in seen:
                continue
            try:
                stage.delete()
            except ProtectedError:
                raise serializers.ValidationError(
                    {
                        "stages": (
                            f"Stage '{stage.name}' has jobs in it and cannot be "
                            "removed."
                        )
                    }
                )


class JobStageEventSerializer(serializers.ModelSerializer):
    from_stage_name = serializers.CharField(source="from_stage.name", read_only=True)
    to_stage_name = serializers.CharField(source="to_stage.name", read_only=True)
    changed_by_name = serializers.CharField(
        source="changed_by.username",
        read_only=True,
    )

    class Meta:
        model = JobStageEvent
        fields = [
            "id",
            "from_stage",
            "from_stage_name",
            "to_stage",
            "to_stage_name",
            "changed_by",
            "changed_by_name",
            "note",
            "created_at",
        ]


class JobMaterialSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(
        source="variant.product.name",
        read_only=True,
    )
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    unit = serializers.CharField(source="variant.product.unit", read_only=True)
    is_consumed = serializers.BooleanField(read_only=True)
    line_total = serializers.SerializerMethodField()

    class Meta:
        model = JobMaterial
        fields = [
            "id",
            "variant",
            "product_name",
            "variant_name",
            "unit",
            "quantity",
            "unit_cost",
            "unit_price",
            "line_total",
            "is_consumed",
            "consumed_at",
            "reversed_at",
            "created_at",
        ]
        read_only_fields = (
            "unit_cost",
            "unit_price",
            "consumed_at",
            "reversed_at",
        )

    def get_line_total(self, material) -> str:
        return str(
            (material.unit_price * material.quantity).quantize(Decimal("0.01"))
        )


class JobServiceSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(
        source="variant.product.name",
        read_only=True,
    )
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    line_total = serializers.SerializerMethodField()

    class Meta:
        model = JobService
        fields = [
            "id",
            "variant",
            "product_name",
            "variant_name",
            "quantity",
            "unit_price",
            "line_total",
            "note",
            "created_at",
        ]
        read_only_fields = ("unit_price",)

    def get_line_total(self, service) -> str:
        return str(service.line_total)


class JobAssetSerializer(serializers.ModelSerializer):
    asset_details = AssetSerializer(source="asset", read_only=True)

    class Meta:
        model = JobAsset
        fields = ["id", "asset", "asset_details"]


class JobSerializer(serializers.ModelSerializer):
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)
    customer_phone = serializers.CharField(source="customer.phone", read_only=True)
    assigned_to_name = serializers.CharField(
        source="assigned_to.username",
        read_only=True,
    )
    assigned_employee_name = serializers.CharField(
        source="assigned_employee.display_name",
        read_only=True,
        default="",
    )
    current_stage_details = WorkflowStageSerializer(
        source="current_stage",
        read_only=True,
    )
    next_stage = serializers.SerializerMethodField()
    sales_channel_name = serializers.CharField(
        source="sales_channel.name",
        read_only=True,
    )
    order_receipt_number = serializers.CharField(
        source="order.receipt_number",
        read_only=True,
    )
    output_variant_name = serializers.CharField(
        source="output_variant.display_name",
        read_only=True,
    )
    assets = JobAssetSerializer(source="job_assets", many=True, read_only=True)
    materials = JobMaterialSerializer(many=True, read_only=True)
    services = JobServiceSerializer(many=True, read_only=True)
    stage_events = JobStageEventSerializer(many=True, read_only=True)
    materials_total = serializers.SerializerMethodField()
    services_total = serializers.SerializerMethodField()
    is_on_hold = serializers.BooleanField(read_only=True)
    # Money and custody are two different facts about a job, and the board needs
    # both: "paid but still on the shelf" is the state a repair shop lives in.
    settlement_state = serializers.CharField(read_only=True)
    custody_state = serializers.CharField(read_only=True)
    order_balance_due = serializers.SerializerMethodField()
    order_amount_paid = serializers.SerializerMethodField()
    order_sale_type = serializers.CharField(source="order.sale_type", read_only=True)

    class Meta:
        model = Job
        fields = [
            "id",
            "job_number",
            "job_type",
            "workflow_template",
            "current_stage",
            "current_stage_details",
            "next_stage",
            "status",
            "customer",
            "customer_name",
            "customer_phone",
            "assigned_to",
            "assigned_to_name",
            "assigned_employee",
            "assigned_employee_name",
            "priority",
            "due_at",
            "completed_at",
            "cancelled_at",
            "handed_over_at",
            "handed_over_to",
            "on_hold_since",
            "hold_reason",
            "held_seconds",
            "is_on_hold",
            "settlement_state",
            "custody_state",
            "symptoms",
            "diagnosis",
            "technician_notes",
            "quoted_price",
            "approved_price",
            "warranty_days",
            "bom",
            "output_variant",
            "output_variant_name",
            "output_quantity",
            "output_unit_cost",
            "output_received_at",
            "sales_channel",
            "sales_channel_name",
            "order",
            "order_receipt_number",
            "order_balance_due",
            "order_amount_paid",
            "order_sale_type",
            "public_token",
            "assets",
            "materials",
            "services",
            "stage_events",
            "materials_total",
            "services_total",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "job_number",
            "job_type",
            "workflow_template",
            "current_stage",
            "status",
            "assigned_employee",
            "completed_at",
            "cancelled_at",
            "handed_over_at",
            "handed_over_to",
            "on_hold_since",
            "hold_reason",
            "held_seconds",
            "bom",
            "output_variant",
            "output_quantity",
            "output_unit_cost",
            "output_received_at",
            "sales_channel",
            "order",
            "public_token",
        )

    def get_next_stage(self, job):
        stages = list(job.workflow_template.stages.all())
        for index, stage in enumerate(stages):
            if stage.pk == job.current_stage_id and index + 1 < len(stages):
                return WorkflowStageSerializer(stages[index + 1]).data
        return None

    def get_materials_total(self, job) -> str:
        # Round per line (matching OrderLine.line_subtotal) so this total equals
        # the invoiced order's subtotal to the cent — the cashier pays exactly
        # this plus labor, and the invoice's payment-total check must agree.
        total = sum(
            (
                (material.unit_price * material.quantity).quantize(Decimal("0.01"))
                for material in job.materials.all()
                if material.reversed_at is None
            ),
            Decimal("0.00"),
        )
        return str(total.quantize(Decimal("0.01")))

    def get_services_total(self, job) -> str:
        total = sum(
            (service.line_total for service in job.services.all()),
            Decimal("0.00"),
        )
        return str(total.quantize(Decimal("0.01")))

    def get_order_balance_due(self, job) -> str | None:
        return str(job.order.balance_due) if job.order_id else None

    def get_order_amount_paid(self, job) -> str | None:
        return str(job.order.amount_paid) if job.order_id else None

    def validate(self, attrs):
        if self.instance is not None and self.instance.is_locked:
            raise serializers.ValidationError(
                {"detail": "Completed or cancelled jobs cannot be edited."}
            )
        return attrs


class JobCreateSerializer(serializers.Serializer):
    workflow_template = serializers.PrimaryKeyRelatedField(
        queryset=WorkflowTemplate.objects.filter(is_active=True),
    )
    customer = serializers.PrimaryKeyRelatedField(
        queryset=Customer.objects.all(),
        required=False,
        allow_null=True,
    )
    asset_ids = serializers.PrimaryKeyRelatedField(
        queryset=Asset.objects.filter(is_active=True),
        many=True,
        required=False,
    )
    assigned_to_id = serializers.IntegerField(required=False, allow_null=True)
    assigned_employee_id = serializers.PrimaryKeyRelatedField(
        source="assigned_employee",
        queryset=Employee.objects.all(),
        required=False,
        allow_null=True,
    )
    priority = serializers.ChoiceField(
        choices=Job.Priority.choices,
        default=Job.Priority.NORMAL,
    )
    due_at = serializers.DateTimeField(required=False, allow_null=True)
    symptoms = serializers.CharField(required=False, allow_blank=True, default="")
    quoted_price = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        required=False,
        allow_null=True,
        min_value=Decimal("0.00"),
    )
    warranty_days = serializers.IntegerField(required=False, default=0, min_value=0)
    # Production jobs only:
    bom = serializers.PrimaryKeyRelatedField(
        queryset=BillOfMaterials.objects.filter(is_active=True),
        required=False,
        allow_null=True,
    )
    batches = serializers.IntegerField(required=False, min_value=1, default=1)

    def validate(self, attrs):
        template = attrs["workflow_template"]
        bom = attrs.get("bom")
        if template.job_type == WorkflowTemplate.JobType.PRODUCTION and bom is None:
            raise serializers.ValidationError(
                {"bom": "Production jobs need a recipe."}
            )
        asset_ids = attrs.get("asset_ids") or []
        customer = attrs.get("customer")
        for asset in asset_ids:
            if customer is None or asset.customer_id != customer.pk:
                raise serializers.ValidationError(
                    {"asset_ids": "Assets must belong to the job's customer."}
                )
        return attrs


class JobAssignSerializer(serializers.Serializer):
    employee_id = serializers.PrimaryKeyRelatedField(
        source="employee",
        queryset=Employee.objects.all(),
        allow_null=True,
    )


class JobTransitionSerializer(serializers.Serializer):
    to_stage = serializers.PrimaryKeyRelatedField(queryset=WorkflowStage.objects.all())
    note = serializers.CharField(required=False, allow_blank=True, default="")
    # Who physically collected the property, when the target stage hands it back.
    handed_over_to = serializers.CharField(
        required=False,
        allow_blank=True,
        default="",
        max_length=120,
    )
    # Manager override for the settlement gate: let the customer take their
    # property without settling. Requires ``operations.release_unpaid_job`` and
    # a non-empty note, and is audited on its own event.
    force_release = serializers.BooleanField(default=False)


class JobHoldSerializer(serializers.Serializer):
    reason = serializers.CharField(max_length=200)


class JobServiceCreateSerializer(serializers.Serializer):
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.active(),
    )
    quantity = serializers.DecimalField(
        max_digits=10,
        decimal_places=3,
        min_value=Decimal("0.001"),
        required=False,
        default=Decimal("1"),
    )
    note = serializers.CharField(
        required=False,
        allow_blank=True,
        default="",
        max_length=200,
    )


class JobMaterialCreateSerializer(serializers.Serializer):
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.active(),
    )
    quantity = serializers.DecimalField(
        max_digits=10,
        decimal_places=3,
        min_value=Decimal("0.001"),
    )
    consume_now = serializers.BooleanField(default=True)


class JobInvoicePaymentSerializer(serializers.Serializer):
    method = serializers.CharField()
    amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.01"),
    )


class JobInvoiceSerializer(serializers.Serializer):
    labor_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        required=False,
        default=Decimal("0.00"),
        min_value=Decimal("0.00"),
    )
    # A credit (آجل) job invoice may be paid partly or not at all — the deposit
    # a workshop takes for parts, or a regular customer settling next week — so
    # payments are only mandatory on a standard sale.
    payments = JobInvoicePaymentSerializer(many=True, required=False, default=list)
    sale_type = serializers.ChoiceField(
        choices=("standard", "credit"),
        required=False,
        default="standard",
    )
    valid_until = serializers.DateField(required=False, allow_null=True)
    acknowledge_over_quote = serializers.BooleanField(default=False)

    def validate(self, attrs):
        if attrs.get("sale_type") != "credit" and not attrs.get("payments"):
            raise serializers.ValidationError(
                {"payments": "A standard job invoice must be paid in full now."}
            )
        return attrs


class BomLineSerializer(serializers.ModelSerializer):
    id = serializers.IntegerField(required=False)
    component_name = serializers.CharField(
        source="component_variant.display_name",
        read_only=True,
    )
    component_product_name = serializers.CharField(
        source="component_variant.product.name",
        read_only=True,
    )
    component_unit = serializers.CharField(
        source="component_variant.product.unit",
        read_only=True,
    )

    class Meta:
        model = BomLine
        fields = [
            "id",
            "component_variant",
            "component_name",
            "component_product_name",
            "component_unit",
            "quantity",
            "waste_percent",
        ]


class BillOfMaterialsSerializer(serializers.ModelSerializer):
    lines = BomLineSerializer(many=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    product_name = serializers.CharField(
        source="variant.product.name",
        read_only=True,
    )
    # A recipe's output is made-to-order by default: selling it consumes the
    # recipe ingredients (via the kitchen job) instead of drawing down its own
    # stock. Untick this for goods produced into stock ahead of time.
    make_to_order = serializers.BooleanField(write_only=True, required=False)
    is_prepared = serializers.BooleanField(
        source="variant.product.is_prepared",
        read_only=True,
    )

    class Meta:
        model = BillOfMaterials
        fields = [
            "id",
            "name",
            "variant",
            "variant_name",
            "product_name",
            "output_quantity",
            "is_active",
            "make_to_order",
            "is_prepared",
            "lines",
            "created_at",
            "updated_at",
        ]

    def validate_lines(self, lines):
        if not lines:
            raise serializers.ValidationError("Recipe needs at least one component.")
        return lines

    def validate(self, attrs):
        variant = attrs.get("variant") or getattr(self.instance, "variant", None)
        for line in attrs.get("lines", []):
            component = line.get("component_variant")
            if component is not None and variant is not None and component.pk == variant.pk:
                raise serializers.ValidationError(
                    {"lines": "A recipe cannot contain its own output."}
                )
        return attrs

    def create(self, validated_data):
        # New recipes default to made-to-order so selling the output consumes
        # the recipe instead of needing its own stock — the common case and the
        # one the POS now expects.
        make_to_order = validated_data.pop("make_to_order", True)
        lines = validated_data.pop("lines")
        bom = BillOfMaterials.objects.create(**validated_data)
        self._sync_lines(bom, lines)
        self._apply_make_to_order(bom, make_to_order)
        return bom

    def update(self, instance, validated_data):
        # On edit, only change the made-to-order flag when the client sends it,
        # so a deliberate produce-to-stock choice is never silently reverted.
        make_to_order = validated_data.pop("make_to_order", None)
        lines = validated_data.pop("lines", None)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save()
        if lines is not None:
            self._sync_lines(instance, lines)
        self._apply_make_to_order(instance, make_to_order)
        return instance

    def _apply_make_to_order(self, bom, make_to_order):
        if make_to_order is None:
            return
        product = bom.variant.product
        if product.is_prepared != make_to_order:
            product.is_prepared = make_to_order
            product.save(update_fields=["is_prepared", "updated_at"])

    def _sync_lines(self, bom, lines):
        existing = {line.pk: line for line in bom.lines.all()}
        seen = set()
        for line_data in lines:
            line_id = line_data.pop("id", None)
            if line_id and line_id in existing:
                line = existing[line_id]
                for field, value in line_data.items():
                    setattr(line, field, value)
                line.save()
                seen.add(line_id)
            else:
                BomLine.objects.create(bom=bom, **line_data)
        for line_id, line in existing.items():
            if line_id not in seen:
                line.delete()


class PublicJobSerializer(serializers.ModelSerializer):
    stage_name = serializers.CharField(source="current_stage.name", read_only=True)

    class Meta:
        model = Job
        fields = [
            "job_number",
            "status",
            "stage_name",
            "due_at",
            "quoted_price",
            "approved_price",
            "updated_at",
        ]
