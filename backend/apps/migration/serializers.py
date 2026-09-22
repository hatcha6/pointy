from rest_framework import serializers

from . import scopes
from .connectors import list_connectors
from .entity_plan import ENTITY_PLAN, ENTITY_PLAN_BY_TYPE
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
    supports_stock_filter = serializers.BooleanField()

    @classmethod
    def catalogue(cls) -> list[dict]:
        return [
            {
                "system_key": connector.system_key,
                "display_name": connector.display_name,
                "supported_entities": list(connector.supported_entities),
                "versions": [version.version_key for version in connector.versions],
                "implemented": connector.implemented,
                "supports_stock_filter": connector.supports_stock_filter,
            }
            for connector in list_connectors()
        ]


class EntitySpecSerializer(serializers.Serializer):
    """The entity catalogue, with the edges the UI needs to stay honest.

    ``dependencies`` travels because the client has to be able to say "sales
    need products and customers, so they are coming too" *before* the run
    starts. The server closes the selection either way; the point of sending
    the graph is that the owner is told, rather than finding out from a summary
    listing three entities they never ticked.

    ``label`` is an English developer fallback — the client renders its own
    Arabic for a known ``entity_type``, which is what keeps this screen from
    being the one place in the app that speaks English.
    """

    entity_type = serializers.CharField()
    label = serializers.CharField()
    implemented = serializers.BooleanField()
    dependencies = serializers.ListField(child=serializers.CharField())

    @classmethod
    def catalogue(cls) -> list[dict]:
        return [
            {
                "entity_type": spec.entity_type,
                "label": spec.label,
                "implemented": spec.implemented,
                "dependencies": list(spec.dependencies),
            }
            for spec in ENTITY_PLAN
        ]


class ImportScopeSerializer(serializers.Serializer):
    """Named "how much of this shop are we taking?" presets (see ``scopes``)."""

    key = serializers.CharField()
    label = serializers.CharField()
    description = serializers.CharField()
    entities = serializers.ListField(child=serializers.CharField(), allow_null=True)
    options = serializers.DictField()
    is_preset = serializers.BooleanField()

    @classmethod
    def catalogue(cls, available=None) -> list[dict]:
        return scopes.catalogue(available)


class MigrationSourceSerializer(serializers.ModelSerializer):
    """An uploaded file and everything we have worked out about it."""

    upload_percent = serializers.IntegerField(read_only=True)
    is_ready = serializers.BooleanField(read_only=True)
    is_busy = serializers.BooleanField(read_only=True)
    is_purged = serializers.BooleanField(read_only=True)
    supported_entities = serializers.SerializerMethodField()
    supports_stock_filter = serializers.SerializerMethodField()

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
            "supports_stock_filter",
            "last_compat_status",
            "last_compat_report",
            "last_run_at",
            "purged_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_supported_entities(self, source):
        return list(self._connector(source).supported_entities) if self._connector(source) else []

    def get_supports_stock_filter(self, source):
        """Can this file be narrowed to what the shop still stocks?

        Sent per source, not just per system, so the client never offers a
        filter the detected connector would silently ignore.
        """
        connector = self._connector(source)
        return bool(connector and connector.supports_stock_filter)

    @staticmethod
    def _connector(source):
        from .connectors import get_connector

        return get_connector(source.system_key) if source.system_key else None


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
    #: A named preset (``scopes.SCOPES``). Overrides the selection and pins the
    #: options that go with it; omit it, or send ``custom``, for a free choice.
    scope = serializers.CharField(required=False, allow_blank=True, default="")
    options = serializers.DictField(required=False, default=dict)

    def validate_scope(self, value):
        if value and value not in scopes.VALID_SCOPE_KEYS:
            raise serializers.ValidationError(
                f"Must be one of {sorted(scopes.VALID_SCOPE_KEYS)}."
            )
        return value

    def validate_selected_entities(self, value):
        # A typo used to be silently dropped, which is how "import only my
        # customers" becomes "import everything": an empty selection means
        # *everything*, so one misspelt entity was the difference between a
        # scoped run and a full one.
        unknown = sorted({entity for entity in (value or []) if entity not in ENTITY_PLAN_BY_TYPE})
        if unknown:
            raise serializers.ValidationError(f"Unknown entity types: {', '.join(unknown)}.")
        return value

    def validate_options(self, value):
        stock_source = (value or {}).get("stock_source")
        if stock_source is not None and stock_source not in VALID_STOCK_SOURCES:
            raise serializers.ValidationError(
                {"stock_source": f"Must be one of {sorted(VALID_STOCK_SOURCES)}."}
            )
        stocked = (value or {}).get("only_stocked_products")
        if stocked is not None and not isinstance(stocked, bool):
            raise serializers.ValidationError(
                {"only_stocked_products": "Must be true or false."}
            )
        basis = (value or {}).get("party_balance_basis")
        if basis is not None and basis not in scopes.VALID_PARTY_BALANCE_BASES:
            raise serializers.ValidationError(
                {
                    "party_balance_basis": (
                        f"Must be one of {sorted(scopes.VALID_PARTY_BALANCE_BASES)}."
                    )
                }
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
