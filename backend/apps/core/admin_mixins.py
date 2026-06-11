"""Shared Django admin mixins for protecting immutable audit records."""


class AppendOnlyAuditAdminMixin:
    """Make an audit-log model read-only in the Django admin.

    These records form an immutable trail written by the application (sales
    events, cash movements, stock movements). The admin must never let anyone,
    superusers included, add, edit, or delete them — otherwise the trail that
    fraud detection and reconciliation rely on could be silently rewritten.
    Viewing remains available for investigation.
    """

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
