from rest_framework import serializers

from apps.catalog.models import ScalePlu

from .drivers import DRIVER_CLASSES, driver_class_for
from .models import Scale, ScalePushJob


class ScaleSerializer(serializers.ModelSerializer):
    driver_label = serializers.SerializerMethodField()
    needs_address = serializers.SerializerMethodField()

    class Meta:
        model = Scale
        fields = [
            "id",
            "name",
            "driver",
            "driver_label",
            "needs_address",
            "host",
            "port",
            "department",
            "options",
            "barcode_rule",
            "is_active",
            "last_push_at",
            "notes",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("last_push_at", "created_at", "updated_at")

    def get_driver_label(self, scale) -> str:
        cls = driver_class_for(scale.driver)
        return cls.label if cls else scale.driver

    def get_needs_address(self, scale) -> bool:
        cls = driver_class_for(scale.driver)
        return bool(cls.needs_address) if cls else True

    def validate(self, attrs):
        driver = attrs.get("driver", getattr(self.instance, "driver", ""))
        cls = driver_class_for(driver)
        if cls is None:
            raise serializers.ValidationError({"driver": "Unknown scale type."})
        host = attrs.get("host", getattr(self.instance, "host", ""))
        # A networked scale with no address is a row that can only ever fail at
        # the moment the shop presses the button, which is the worst time to
        # find out.
        if cls.needs_address and not str(host or "").strip():
            raise serializers.ValidationError(
                {"host": "This scale type needs the scale's address on the network."}
            )
        return attrs


class ScalePushJobSerializer(serializers.ModelSerializer):
    requested_by_name = serializers.CharField(
        source="requested_by.get_full_name",
        read_only=True,
        default="",
    )

    class Meta:
        model = ScalePushJob
        fields = [
            "id",
            "scale",
            "status",
            "requested_by",
            "requested_by_name",
            "plu_count",
            "sent_count",
            "failed_count",
            "errors",
            "message",
            "filename",
            "finished_at",
            "created_at",
        ]
        read_only_fields = fields


class ScalePluSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(
        source="variant.product.name", read_only=True
    )
    variant_name = serializers.CharField(
        source="variant.display_name", read_only=True
    )
    printed_name = serializers.CharField(read_only=True)

    class Meta:
        model = ScalePlu
        fields = [
            "id",
            "variant",
            "product_name",
            "variant_name",
            "plu_number",
            "label_name",
            "printed_name",
            "tare_grams",
            "shelf_life_days",
            "is_active",
            "created_at",
            "updated_at",
        ]
        # The number is allocated, never chosen: a shop that could type one in
        # could type in one that is already on a shelf label for something else.
        read_only_fields = ("plu_number", "created_at", "updated_at")


class ScaleDriverSerializer(serializers.Serializer):
    key = serializers.CharField()
    label = serializers.CharField()
    needs_address = serializers.BooleanField()
    default_port = serializers.IntegerField()

    @staticmethod
    def catalog() -> list[dict]:
        return [
            {
                "key": cls.key,
                "label": cls.label,
                "needs_address": cls.needs_address,
                "default_port": cls.default_port,
            }
            for cls in DRIVER_CLASSES
        ]
