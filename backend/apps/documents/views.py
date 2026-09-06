"""Reading a document's trail.

One endpoint rather than an action on each of the eight viewsets: the trail has
the same shape whichever document it belongs to, and a client that has learned
to read one has learned to read them all.

It is always asked about *one* document. A trail listing across every document
in the shop is not a thing anyone needs, and it would be a listing whose rows
each require a different permission — so the endpoint refuses to answer without
a type and an id, and checks the view permission of the model that type names.
"""

from rest_framework import mixins, viewsets
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission

from . import registry
from .models import DocumentEvent
from .serializers import DocumentEventSerializer


class DocumentEventViewSet(mixins.ListModelMixin, viewsets.GenericViewSet):
    serializer_class = DocumentEventSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    queryset = DocumentEvent.objects.select_related("actor")

    def get_required_permissions(self, request):
        """Whatever it takes to *see* the document itself.

        A sale's trail is as sensitive as the sale, so it asks for the same
        permission the sale does. An unrecognised type falls back to the
        trail's own permission, which no role holds by default.
        """
        doc_type = registry.by_key(request.query_params.get("document_type", ""))
        if doc_type is None:
            return ("documents.view_documentevent",)
        meta = doc_type.model._meta
        return (f"{meta.app_label}.view_{meta.model_name}",)

    def get_queryset(self):
        document_type = self.request.query_params.get("document_type", "").strip()
        object_id = self.request.query_params.get("object_id", "").strip()
        if not document_type or not object_id:
            raise ValidationError(
                {
                    "detail": (
                        "document_type and object_id are required: a trail "
                        "belongs to one document."
                    )
                }
            )
        if registry.by_key(document_type) is None:
            raise ValidationError({"document_type": "Unknown document type."})
        try:
            object_id = int(object_id)
        except ValueError as exc:
            raise ValidationError({"object_id": "Must be a number."}) from exc
        return super().get_queryset().filter(
            document_type=document_type, object_id=object_id
        )
