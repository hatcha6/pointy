from rest_framework import serializers

from .connectors import get_connector, list_connectors
from .entity_plan import ENTITY_PLAN
from .models import MigrationIssue, MigrationRun, MigrationSource
from .reconstruct import VALID_STOCK_SOURCES


class MigrationSystemSerializer(serializers.Serializer):
    """Read-only catalogue entry describing one available connector."""

    system_key = serializers.CharField()
    display_name = serializers.CharField()
    required_transport = serializers.CharField()
    supported_entities = serializers.ListField(child=serializers.CharField())
    versions = serializers.ListField(child=serializers.CharField())
    implemented = serializers.BooleanField()
    recommended_options = serializers.DictField()

    @classmethod
    def catalogue(cls) -> list[dict]:
        return [
            {
                "system_key": connector.system_key,
                "display_name": connector.display_name,
                "required_transport": connector.required_transport,
                "supported_entities": list(connector.supported_entities),
                "versions": [version.version_key for version in connector.versions],
                "implemented": connector.implemented,
                "recommended_options": dict(connector.recommended_options or {}),
            }
            for connector in list_connectors()
        ]


class EntitySpecSerializer(serializers.Serializer):
    entity_type = serializers.CharField()
    label = serializers.CharField()
    implemented = serializers.BooleanField()

    @classmethod
    def catalogue(cls) -> list[dict]:
        return [
            {"entity_type": spec.entity_type, "label": spec.label, "implemented": spec.implemented}
            for spec in ENTITY_PLAN
        ]


class MigrationSourceSerializer(serializers.ModelSerializer):
    # Write-only like BioTime: an omitted/blank password keeps the stored one.
    password = serializers.CharField(
        write_only=True, required=False, allow_blank=True, trim_whitespace=False
    )
    has_password = serializers.SerializerMethodField()

    class Meta:
        model = MigrationSource
        fields = [
            "id",
            "name",
            "system_key",
            "transport_kind",
            "host",
            "port",
            "database_name",
            "username",
            "password",
            "has_password",
            "extra_options",
            "detected_version",
            "last_compat_status",
            "last_compat_report",
            "last_run_at",
            "credentials_cleared",
            "is_archived",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "detected_version",
            "last_compat_status",
            "last_compat_report",
            "last_run_at",
            "credentials_cleared",
            "created_at",
            "updated_at",
        ]

    def get_has_password(self, source):
        return bool(source.password)

    def validate(self, attrs):
        system_key = attrs.get("system_key") or getattr(self.instance, "system_key", None)
        transport_kind = attrs.get("transport_kind") or getattr(
            self.instance, "transport_kind", None
        )
        connector = get_connector(system_key) if system_key else None
        if system_key and connector is None:
            raise serializers.ValidationError({"system_key": "Unknown source system."})
        if connector and transport_kind and connector.required_transport != transport_kind:
            raise serializers.ValidationError(
                {
                    "transport_kind": (
                        f"{connector.display_name} requires a "
                        f"{connector.required_transport} connection."
                    )
                }
            )
        return attrs

    def update(self, instance, validated_data):
        password = validated_data.pop("password", None)
        if password:
            instance.password = password
            instance.credentials_cleared = False
        return super().update(instance, validated_data)


class MigrationRunSerializer(serializers.ModelSerializer):
    issue_count = serializers.SerializerMethodField()

    class Meta:
        model = MigrationRun
        fields = [
            "id",
            "source",
            "mode",
            "status",
            "selected_entities",
            "options",
            "progress_percent",
            "progress_message",
            "current_entity",
            "summary",
            "error_message",
            "issue_count",
            "initiated_by_username",
            "created_at",
            "updated_at",
            "started_at",
            "completed_at",
        ]
        read_only_fields = fields

    def get_issue_count(self, run):
        # Prefer an annotation if the viewset provided one.
        annotated = getattr(run, "issue_count", None)
        if annotated is not None:
            return annotated
        return run.issues.count()


class MigrationRunCreateSerializer(serializers.Serializer):
    source = serializers.PrimaryKeyRelatedField(queryset=MigrationSource.objects.all())
    mode = serializers.ChoiceField(choices=MigrationRun.Mode.choices)
    selected_entities = serializers.ListField(
        child=serializers.CharField(), required=False, default=list
    )
    options = serializers.DictField(required=False, default=dict)

    def validate_options(self, value):
        stock_source = (value or {}).get("stock_source")
        if stock_source is not None and stock_source not in VALID_STOCK_SOURCES:
            raise serializers.ValidationError(
                {"stock_source": f"Must be one of {sorted(VALID_STOCK_SOURCES)}."}
            )
        return value


class MigrationIssueSerializer(serializers.ModelSerializer):
    class Meta:
        model = MigrationIssue
        fields = [
            "id",
            "entity_type",
            "source_key",
            "severity",
            "code",
            "message",
            "detail",
            "created_at",
        ]
        read_only_fields = fields
