"""API shapes for the invoice intake.

Read side: the intake with its extraction, plan and counts — everything the
review card renders in one GET, so a client that lost the create response (or
polled after the 90-second handoff) can rebuild the whole card from the id.

Write side: two small input serializers. The plan itself is deliberately a plain
JSON field rather than a nested serializer tree: it is a *proposal* the card
edits freely, and validating its interior twice (here and again in every real
serializer the apply dispatches through) would only invent a second, drifting
definition of a valid purchase order.
"""

from rest_framework import serializers

from apps.attachments.models import Attachment
from apps.purchasing.models import Supplier

from .models import InvoiceIntake


class InvoiceIntakeSerializer(serializers.ModelSerializer):
    supplier_name = serializers.CharField(source="supplier.name", read_only=True)
    purchase_order_number = serializers.CharField(
        source="purchase_order.order_number",
        read_only=True,
    )
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    counts = serializers.SerializerMethodField()
    needs_review = serializers.BooleanField(read_only=True)

    class Meta:
        model = InvoiceIntake
        fields = [
            "id",
            "source",
            "status",
            "pages",
            "extraction",
            "plan",
            "review_edits",
            "confidence_summary",
            "counts",
            "needs_review",
            "supplier",
            "supplier_name",
            "purchase_order",
            "purchase_order_number",
            "created_by",
            "created_by_username",
            "error",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_counts(self, intake):
        return intake.counts()


class InvoiceIntakeCreateSerializer(serializers.Serializer):
    """Start an intake.

    ``extraction`` is the vision model's raw ``InvoiceExtraction`` JSON — raw on
    purpose: normalising it is the pipeline's first step, and a client that
    pre-normalised would be a second implementation of that. Omit it to open an
    intake that is still capturing pages.
    """

    source = serializers.ChoiceField(
        choices=InvoiceIntake.Source.choices,
        default=InvoiceIntake.Source.CHAT,
    )
    pages = serializers.PrimaryKeyRelatedField(
        queryset=Attachment.objects.active(),
        many=True,
        required=False,
    )
    extraction = serializers.JSONField(required=False)
    # The user may already know who the invoice is from (they picked the
    # supplier before photographing it), which pins tier 4 to that supplier's
    # history instead of a name match.
    supplier = serializers.PrimaryKeyRelatedField(
        queryset=Supplier.objects.all(),
        required=False,
        allow_null=True,
    )
    review_edits = serializers.JSONField(required=False)


class InvoiceIntakeApplyOptionsSerializer(serializers.Serializer):
    """What to do beyond creating the draft. Each extra step is gated by the
    permission that gates it on the purchasing screen — the apply dispatches
    through those same actions."""

    submit = serializers.BooleanField(default=False)
    receive = serializers.BooleanField(default=False)
    pay = serializers.BooleanField(default=False)
    amount = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        required=False,
        allow_null=True,
    )
    method = serializers.CharField(required=False, allow_blank=True)
    paid_at = serializers.DateField(required=False, allow_null=True)
    # The buyer has seen the cost warnings on the card; the purchasing screen
    # sends the same acknowledgement.
    acknowledge_cost_warnings = serializers.BooleanField(default=True)


class InvoiceIntakeApplySerializer(serializers.Serializer):
    """The edited plan coming back from the review card. Omitting ``plan``
    applies the stored one unchanged."""

    plan = serializers.JSONField(required=False)
    options = InvoiceIntakeApplyOptionsSerializer(required=False)

    def validate_plan(self, value):
        if not isinstance(value, dict):
            raise serializers.ValidationError("The plan must be an object.")
        if not isinstance(value.get("lines"), list) or not value["lines"]:
            raise serializers.ValidationError("The plan must carry at least one line.")
        return value
