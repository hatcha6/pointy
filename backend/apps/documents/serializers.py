"""The trail, on the wire.

Codes rather than prose: the app is Arabic-first and does its own wording, the
same way it does for print audit events. What the server owes the client is the
machine-readable fact — which action, on which document, by whom, when, and the
words the person typed as their reason.
"""

from rest_framework import serializers

from .models import DocumentEvent


class DocumentEventSerializer(serializers.ModelSerializer):
    actor_username = serializers.SerializerMethodField()

    class Meta:
        model = DocumentEvent
        fields = [
            "id",
            "document_type",
            "object_id",
            "document_number",
            "action",
            "reason",
            "details",
            "actor",
            "actor_username",
            "created_at",
        ]
        read_only_fields = fields

    def get_actor_username(self, event) -> str | None:
        return event.actor.username if event.actor_id else None


class DocumentLifecycleFields(serializers.Serializer):
    """The lifecycle, for any document's own serializer.

    Mixed in ahead of ``ModelSerializer`` so its declared fields are collected,
    and its names added to that serializer's ``fields`` list through
    ``LIFECYCLE_FIELDS``. Everything here is read-only: a lifecycle moves
    through the transitions in ``apps.documents.services`` and no other way,
    least of all a ``PATCH``.
    """

    LIFECYCLE_FIELDS = (
        "doc_status",
        "cancelled_at",
        "cancel_reason",
        "cancelled_by_username",
        "superseded_by",
        "amendment_index",
    )

    doc_status = serializers.CharField(read_only=True)
    cancelled_at = serializers.DateTimeField(read_only=True)
    cancel_reason = serializers.CharField(read_only=True)
    cancelled_by_username = serializers.SerializerMethodField()
    superseded_by = serializers.IntegerField(
        source="superseded_by_id", read_only=True
    )
    amendment_index = serializers.IntegerField(read_only=True)

    def get_cancelled_by_username(self, document) -> str | None:
        return (
            document.cancelled_by.username if document.cancelled_by_id else None
        )
