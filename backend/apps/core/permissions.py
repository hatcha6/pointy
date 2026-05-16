from rest_framework.permissions import BasePermission

from .roles import user_is_manager


class IsManager(BasePermission):
    def has_permission(self, request, view):
        return user_is_manager(request.user)


class HasPointyPermission(BasePermission):
    """
    Requires viewsets to declare explicit Django permission codes per action.
    """

    message = "You do not have permission to perform this action."

    def has_permission(self, request, view):
        if not request.user or not request.user.is_authenticated:
            return False

        required_permissions = self._required_permissions(request, view)
        if required_permissions is None:
            return False
        if not required_permissions:
            return True
        return request.user.has_perms(required_permissions)

    def _required_permissions(self, request, view):
        if hasattr(view, "get_required_permissions"):
            return view.get_required_permissions(request)

        permission_map = getattr(view, "permission_map", None)
        if permission_map is None:
            return None

        action = getattr(view, "action", None)
        if action in permission_map:
            return permission_map[action]
        return permission_map.get(request.method)
