from rest_framework.permissions import BasePermission

from .roles import user_is_manager


class IsManager(BasePermission):
    def has_permission(self, request, view):
        return user_is_manager(request.user)
