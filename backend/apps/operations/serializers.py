from decimal import Decimal

from django.db.models.deletion import ProtectedError
from rest_framework import serializers

from apps.catalog.models import BillOfMaterials, BomLine, ProductVariant
from apps.customers.models import Asset, Customer
from apps.employees.models import Employee
from .models import (
    Job,
    JobAsset,
    JobMaterial,
    JobStageEvent,
    WorkflowStage,
    WorkflowTemplate,
)


class AssetSerializer(serializers.ModelSerializer):
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)
    display_name = serializers.CharField(read_only=True)
    job_count = serializers.IntegerField(read_only=True, default=0)

    class Meta:
        model = Asset
        fields = [
            "id",
            "customer",
            "customer_name",
            "asset_type",
            "brand",
            "model_name",
            "serial_number",
            "imei",
            "color",
            "notes",
            "display_name",
            "job_count",
            "is_active",
            "created_at",
            "updated_at",
        ]


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
    stage_events = JobStageEventSerializer(many=True, read_only=True)
    materials_total = serializers.SerializerMethodField()

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
            "public_token",
            "assets",
            "materials",
            "stage_events",
            "materials_total",
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
    payments = JobInvoicePaymentSerializer(many=True, allow_empty=False)


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
