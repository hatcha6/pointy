from rest_framework import serializers

from .connectors import list_connectors
from .entity_plan import ENTITY_PLAN
from .models import MigrationIssue, MigrationRun, MigrationSource
from .reconstruct import VALID_STOCK_SOURCES


class MigrationSystemSerializer(serializers.Serializer):
    """Read-only catalogue of the systems Pointy can read.

    Nobody picks from this any more — the system is detected from the uploaded
    file's schema. It stays because the screen should be able to answer "will my
    system work?" *before* someone spends twenty minutes uploading, and because
    an unrecognised file's error is more useful next to the list of what is
    recognised.
    """

    system_key = serializers.CharField()
    display_name = serializers.CharField()
    supported_entities = serializers.ListField(child=serializers.CharField())
    versions = serializers.ListField(child=serializers.CharField())
    implemented = serializers.BooleanField()

    @classmethod
    def catalogue(cls) -> list[dict]:
        return [
            {
                "system_key": connector.system_key,
                "display_name": connector.display_name,
                "supported_entities": list(connector.supported_entities),
                "versions": [version.version_key for version in connector.versions],
                "implemented": connector.implemented,
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
    """An uploaded file and everything we have worked out about it."""

    upload_percent = serializers.IntegerField(read_only=True)
    is_ready = serializers.BooleanField(read_only=True)
    is_busy = serializers.BooleanField(read_only=True)
    is_purged = serializers.BooleanField(read_only=True)
    supported_entities = serializers.SerializerMethodField()

    class Meta:
        model = MigrationSource
        fields = [
            "id",
            "name",
            "original_filename",
            "declared_size_bytes",
            "received_bytes",
            "upload_percent",
            "upload_state",
            "is_ready",
            "is_busy",
            "is_purged",
            "staged_size_bytes",
            "prepared_size_bytes",
            "stages",
            "error_message",
            "system_key",
            "detected_version",
            "detection",
            "analysis",
            "supported_entities",
            "last_compat_status",
            "last_compat_report",
            "last_run_at",
            "purged_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_supported_entities(self, source):
        from .connectors import get_connector

        connector = get_connector(source.system_key) if source.system_key else None
        return list(connector.supported_entities) if connector else []


class UploadBeginSerializer(serializers.Serializer):
    filename = serializers.CharField(max_length=255)
    size_bytes = serializers.IntegerField(min_value=1)


class UploadCompleteSerializer(serializers.Serializer):
    # Optional: a client that can hash cheaply sends it and gets end-to-end
    # verification; one that cannot still gets the size check.
    checksum_sha256 = serializers.CharField(
        max_length=64, required=False, allow_blank=True, default=""
    )


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
            "stages",
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
