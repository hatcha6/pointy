from rest_framework.permissions import BasePermission


class HasSurveillancePermission(BasePermission):
    """Gate a non-viewset streaming view on one Django permission.

    The streaming endpoints are plain ``APIView``s rather than viewset actions —
    they return ``StreamingHttpResponse``, not a DRF ``Response`` — so they
    cannot use the project's ``permission_map`` convention. Each view names its
    permission in ``required_permission`` instead.
    """

    message = "You do not have permission to view camera footage."

    def has_permission(self, request, view):
        user = getattr(request, "user", None)
        if user is None or not user.is_authenticated:
            return False
        required = getattr(view, "required_permission", "")
        if not required:
            return False
        return user.has_perm(required)
