"""The review screen's payloads: the proposal, its products, and one row of it.

Kept out of ``serializers.py`` for the reason §12's screen is kept out of the
import flow — a collapse is an argument a shop has to be able to disagree with,
and the shapes that carry it are about editing rather than about progress.
"""

from __future__ import annotations

from rest_framework import serializers

from apps.inventory.identity import IdentifierKind
from apps.inventory.unit_attributes import validate_attributes

from .collapse.extract import HIGH_CONFIDENCE, LOW_CONFIDENCE, cluster_key, option_label
from .collapse.planner import clusters_for
from .models import CollapseCandidate, CollapsePlan

#: The axes a candidate's options may name. Anything else is refused rather than
#: stored: an option nobody can render is an option that becomes a variant with
#: a blank name.
EDITABLE_OPTION_AXES = ("storage", "colour")


class CollapsePlanSerializer(serializers.ModelSerializer):
    is_editable = serializers.BooleanField(read_only=True)
    is_active = serializers.BooleanField(read_only=True)
    asset_type_name = serializers.CharField(source="asset_type.name", read_only=True)
    thresholds = serializers.SerializerMethodField()

    class Meta:
        model = CollapsePlan
        fields = [
            "id",
            "source",
            "status",
            "is_editable",
            "is_active",
            "stages",
            "error_message",
            "asset_type",
            "asset_type_name",
            "warranty_days",
            "stats",
            "thresholds",
            "built_at",
            "approved_at",
            "approved_by_username",
            "applied_run",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            field for field in fields if field not in ("asset_type", "warranty_days")
        ]

    def get_thresholds(self, _plan):
        """What the client should call "needs a look" — decided here, once."""
        return {"low": LOW_CONFIDENCE, "high": HIGH_CONFIDENCE}

    def validate(self, attrs):
        if self.instance is not None and not self.instance.is_editable:
            raise serializers.ValidationError({"detail": "لا يمكن تعديل اقتراح تم اعتماده."})
        return attrs


class CollapseCandidateSerializer(serializers.ModelSerializer):
    needs_review = serializers.BooleanField(read_only=True)
    option_labels = serializers.SerializerMethodField()

    class Meta:
        model = CollapseCandidate
        fields = [
            "id",
            "source_key",
            "source_name",
            "decision",
            "stem",
            "stem_key",
            "identifier",
            "identifier_kind",
            "options",
            "option_labels",
            "attributes",
            "unit_status",
            "unit_cost",
            "list_price",
            "sold_price",
            "acquired_at",
            "sold_at",
            "confidence",
            "reasons",
            "edited",
            "needs_review",
        ]
        read_only_fields = [
            "id",
            "source_key",
            "source_name",
            "stem_key",
            "option_labels",
            "confidence",
            "reasons",
            "edited",
            "needs_review",
        ]

    def get_option_labels(self, candidate):
        return {
            axis: option_label(axis, value) for axis, value in (candidate.options or {}).items()
        }

    def validate_identifier_kind(self, value):
        """A kind the unit register can render. Free text here would put a
        label nobody has on every screen the article appears on."""
        known = {choice for choice, _label in IdentifierKind.CHOICES}
        if value and value not in known:
            raise serializers.ValidationError(f"نوع معرّف غير معروف: {value}.")
        return value

    def validate_attributes(self, value):
        """The same coercion a unit's own attributes go through.

        A battery percentage typed here lands on `StockUnit.attributes`
        untouched, so it has to be the shape the picker, the filters and the
        label printer expect — «86», not «86%» and not «ممتاز».
        """
        if not isinstance(value, dict):
            raise serializers.ValidationError("الخصائص يجب أن تكون كائنًا.")
        asset_type_id = self.instance.plan.asset_type_id if self.instance else None
        if asset_type_id is None:
            return {}
        return validate_attributes(value, asset_type_id=asset_type_id, partial=True)

    def validate_options(self, value):
        if not isinstance(value, dict):
            raise serializers.ValidationError("الخيارات يجب أن تكون كائنًا.")
        unknown = sorted(set(value) - set(EDITABLE_OPTION_AXES))
        if unknown:
            raise serializers.ValidationError(f"خيارات غير معروفة: {', '.join(unknown)}.")
        return {axis: str(raw)[:64] for axis, raw in value.items() if str(raw or "").strip()}

    def validate(self, attrs):
        plan = self.instance.plan
        if not plan.is_editable:
            raise serializers.ValidationError({"detail": "لا يمكن تعديل اقتراح تم اعتماده."})
        decision = attrs.get("decision", self.instance.decision)
        stem = attrs.get("stem", self.instance.stem)
        identifier = attrs.get("identifier", self.instance.identifier)
        if decision == CollapseCandidate.Decision.COLLAPSE:
            if not str(stem or "").strip():
                raise serializers.ValidationError({"stem": "اسم المنتج مطلوب لدمج هذا الصنف."})
            if not str(identifier or "").strip():
                raise serializers.ValidationError({"identifier": "المعرّف مطلوب لدمج هذا الصنف."})
        return attrs

    def update(self, instance, validated_data):
        """A person's answer replaces the parser's, and says so.

        ``stem_key`` is re-derived rather than accepted: it is what decides
        which product this lands in, and a client that could set it
        independently of the name could put two differently-named rows in one
        product and one name in two.
        """
        for field, value in validated_data.items():
            setattr(instance, field, value)
        if instance.decision == CollapseCandidate.Decision.KEEP:
            instance.stem_key = ""
        else:
            instance.stem_key = cluster_key(instance.stem)[:255]
        instance.edited = True
        instance.save()
        return instance


class CollapseClusterSerializer(serializers.Serializer):
    """One proposed product: what it is called and what it would hold."""

    stem_key = serializers.CharField()
    stem = serializers.CharField()
    products = serializers.IntegerField()
    variants = serializers.IntegerField()
    units = serializers.IntegerField()
    units_in_stock = serializers.IntegerField()
    units_sold = serializers.IntegerField()
    lowest_confidence = serializers.DecimalField(max_digits=3, decimal_places=2)
    needs_review = serializers.IntegerField()
    option_values = serializers.DictField()
    option_labels = serializers.DictField()

    @classmethod
    def for_plan(cls, plan) -> list[dict]:
        return cls(clusters_for(plan), many=True).data


class CollapseRenameSerializer(serializers.Serializer):
    stem_key = serializers.CharField(max_length=255)
    stem = serializers.CharField(max_length=255)
