from django.contrib.auth import get_user_model
from django.contrib.auth import login, logout
from django.middleware.csrf import get_token
from rest_framework import status, views, viewsets
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from .permissions import HasPointyPermission
from .roles import ensure_role_groups
from .models import ShopSettings
from .serializers import (
    LoginSerializer,
    PosUserSerializer,
    ShopSettingsSerializer,
    UserSerializer,
)


@api_view(["POST"])
@permission_classes([AllowAny])
def login_view(request):
    serializer = LoginSerializer(data=request.data, context={"request": request})
    serializer.is_valid(raise_exception=True)
    user = serializer.validated_data["user"]
    login(request, user)
    return Response({"user": UserSerializer(user).data, "csrf_token": get_token(request)})


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def logout_view(request):
    logout(request)
    return Response(status=status.HTTP_204_NO_CONTENT)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def me_view(request):
    return Response({"user": UserSerializer(request.user).data, "csrf_token": get_token(request)})


class PosUserViewSet(viewsets.ModelViewSet):
    serializer_class = PosUserSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("auth.view_user",),
        "retrieve": ("auth.view_user",),
        "create": ("auth.add_user",),
        "update": ("auth.change_user",),
        "partial_update": ("auth.change_user",),
        "destroy": ("auth.delete_user",),
    }
    queryset = get_user_model().objects.order_by("username")
    filterset_fields = ("is_active", "groups__name")
    search_fields = ("username", "email", "first_name", "last_name")
    ordering_fields = ("username", "date_joined")

    def initial(self, request, *args, **kwargs):
        ensure_role_groups()
        return super().initial(request, *args, **kwargs)


class ShopSettingsView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        if request.method in ("PUT", "PATCH"):
            return ("core.change_shopsettings",)
        return ("core.view_shopsettings",)

    def get(self, request):
        serializer = ShopSettingsSerializer(ShopSettings.load())
        return Response(serializer.data)

    def patch(self, request):
        settings = ShopSettings.load()
        serializer = ShopSettingsSerializer(settings, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)
