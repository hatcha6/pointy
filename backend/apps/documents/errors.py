"""What a refused transition looks like on the wire.

Every error here renders as itself through DRF rather than as a 500: a frozen
field is a 400 carrying the field name, a blocked cancellation is a 400 carrying
the documents that block it, and a transition the user may not perform is a 403
— the same shape ``apps.core.period_lock`` already uses for a closed period.
"""

from django.core.exceptions import PermissionDenied
from rest_framework import serializers


class DocumentFrozen(serializers.ValidationError):
    """A write aimed at a field of a document that is no longer a draft."""

    def __init__(self, *, model_label, number, fields):
        self.model_label = model_label
        self.number = number
        self.fields = tuple(fields)
        joined = ", ".join(self.fields)
        super().__init__(
            {
                "code": "document_frozen",
                "detail": (
                    f"{number or model_label} has been submitted; "
                    f"{joined} cannot be changed."
                ),
                "fields": list(self.fields),
            }
        )


class InvalidTransition(serializers.ValidationError):
    """The document is not in a state this transition can start from."""

    def __init__(self, *, transition, from_status, number=None):
        self.transition = transition
        self.from_status = from_status
        super().__init__(
            {
                "code": "invalid_transition",
                "detail": (
                    f"A {from_status} document cannot be {transition}ed"
                    + (f" ({number})." if number else ".")
                ),
                "from_status": from_status,
                "transition": transition,
            }
        )


class CorrectionNotOffered(serializers.ValidationError):
    """This document type does not correct itself that way."""

    def __init__(self, *, correction, model_label, offered):
        super().__init__(
            {
                "code": "correction_not_offered",
                "detail": (
                    f"{model_label} does not support {correction}; "
                    f"it is corrected by {', '.join(offered) or 'nothing'}."
                ),
                "offered": list(offered),
            }
        )


class DocumentBlocked(serializers.ValidationError):
    """Something downstream still points at this document.

    Unlike ERPNext's bare "Cannot cancel because it is linked with Payment
    Entry", the payload names the actual rows, so the caller can show the user
    what to undo first instead of leaving them to guess.
    """

    def __init__(self, *, number, blockers):
        self.blockers = list(blockers)
        described = "، ".join(item["label"] for item in self.blockers)
        super().__init__(
            {
                "code": "document_blocked",
                "detail": (
                    f"{number} cannot be cancelled while it is referenced by: "
                    f"{described}."
                ),
                "blockers": self.blockers,
            }
        )


class TransitionNotPermitted(PermissionDenied):
    """The user may not perform this transition on this document."""

    def __init__(self, message):
        super().__init__(message)


__all__ = [
    "CorrectionNotOffered",
    "DocumentBlocked",
    "DocumentFrozen",
    "InvalidTransition",
    "TransitionNotPermitted",
]
