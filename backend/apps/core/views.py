from django.contrib.auth import get_user_model
from django.contrib.auth import login, logout
from django.middleware.csrf import get_token
from rest_framework import status, viewsets
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from .permissions import IsManager
from .roles import ensure_role_groups
from .serializers import LoginSerializer, PosUserSerializer, UserSerializer


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
    permission_classes = [IsManager]
    queryset = get_user_model().objects.order_by("username")
    filterset_fields = ("is_active", "groups__name")
    search_fields = ("username", "email", "first_name", "last_name")
    ordering_fields = ("username", "date_joined")

    def initial(self, request, *args, **kwargs):
        ensure_role_groups()
        return super().initial(request, *args, **kwargs)
