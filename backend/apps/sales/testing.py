"""Helpers for building sales data in tests.

A hand-built order is assembled in the opposite order from a real one: the row
first, then its lines, then its figures. A real sale is issued only once all
three exist, and from then on it is frozen — so a fixture that creates an order
already ``paid`` and fills it in afterwards is describing something that cannot
happen. ``issue`` is the last step it was missing.
"""

from apps.documents.statuses import DocumentStatus

from .models import Order


def issue(order, *, status=Order.Status.PAID):
    """Mark a fully built order issued, the way checkout does at the end."""
    order.doc_status = DocumentStatus.SUBMITTED
    order.status = status
    order.save(update_fields=["doc_status", "status", "updated_at"])
    return order


__all__ = ["issue"]
