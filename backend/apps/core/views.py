from django.contrib.auth import get_user_model
from django.contrib.auth import login, logout
from django.middleware.csrf import get_token
from rest_framework import status, views, viewsets
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

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
    record_domain_event(
        name="auth.login.succeeded",
        event_type=AnalyticsEvent.EventType.SECURITY,
        user=user,
        entity_type="user",
        entity_id=user.pk,
        attributes={"username_present": bool(user.username), "is_staff": user.is_staff},
    )
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

    def perform_create(self, serializer):
        role = self.request.data.get("role", "")
        user = serializer.save()
        record_domain_event(
            name="users.user.created",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=self.request.user,
            entity_type="user",
            entity_id=user.pk,
            attributes={
                "target_user_id": user.pk,
                "assigned_role": role,
                "is_active": user.is_active,
            },
        )

    def perform_update(self, serializer):
        changed_fields = sorted(serializer.validated_data.keys())
        password_changed = "password" in serializer.validated_data
        role = serializer.validated_data.get("role")
        user = serializer.save()
        record_domain_event(
            name="users.user.updated",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=self.request.user,
            entity_type="user",
            entity_id=user.pk,
            attributes={
                "target_user_id": user.pk,
                "changed_fields": changed_fields,
                "assigned_role": role or "",
                "is_active": user.is_active,
                "password_changed": password_changed,
            },
        )

    def perform_destroy(self, instance):
        target_user_id = instance.pk
        is_active = instance.is_active
        instance.delete()
        record_domain_event(
            name="users.user.deleted",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.WARNING,
            user=self.request.user,
            entity_type="user",
            entity_id=target_user_id,
            attributes={
                "target_user_id": target_user_id,
                "was_active": is_active,
            },
        )


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
        before = {
            field: getattr(settings, field)
            for field in serializer.validated_data
            if hasattr(settings, field)
        }
        serializer.save()
        changed_fields = [
            field
            for field, previous in before.items()
            if getattr(settings, field) != previous
        ]
        record_domain_event(
            name="settings.shop.updated",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=(
                AnalyticsEvent.Severity.WARNING
                if "allow_overselling" in changed_fields and settings.allow_overselling
                else AnalyticsEvent.Severity.INFO
            ),
            user=request.user,
            entity_type="shop_settings",
            entity_id=settings.pk,
            attributes={
                "changed_fields": sorted(changed_fields),
                "allow_overselling": settings.allow_overselling,
                "auto_print_receipts": settings.auto_print_receipts,
                "require_opening_cash": settings.require_opening_cash,
                "cashier_return_window_hours": settings.cashier_return_window_hours,
                "low_stock_threshold": settings.low_stock_threshold,
                "enable_cash_payments": settings.enable_cash_payments,
                "enable_card_payments": settings.enable_card_payments,
                "enable_transfer_payments": settings.enable_transfer_payments,
            },
        )
        return Response(serializer.data)
