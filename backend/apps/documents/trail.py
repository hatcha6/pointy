"""Writing the document trail.

One function, so that "what happened to this document" has one shape whichever
domain the document came from. Generalises
``purchasing.PurchaseOrderAuditEvent``, which proved the need for exactly this
and could only ever answer it for purchase orders.
"""

from apps.documents import registry
from apps.documents.models import DocumentEvent


def record(document, action, *, doc_type=None, actor=None, reason="", details=None):
    doc_type = doc_type or registry.for_instance(document)
    if doc_type is None:
        return None
    return DocumentEvent.objects.create(
        document_type=doc_type.key,
        object_id=document.pk,
        document_number=doc_type.number_of(document)[:64],
        action=action,
        reason=reason or "",
        details=details or {},
        actor=actor,
    )


def history(document, *, doc_type=None):
    doc_type = doc_type or registry.for_instance(document)
    if doc_type is None:
        return DocumentEvent.objects.none()
    return DocumentEvent.objects.filter(
        document_type=doc_type.key, object_id=document.pk
    )


__all__ = ["history", "record"]
