from django.contrib.auth import get_user_model
from django.contrib.auth import login, logout
from django.middleware.csrf import get_token
from rest_framework import parsers, status, views, viewsets
from rest_framework.decorators import action, api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSerializer
from apps.attachments.services import active_attachments_for, content_type_for_upload

from .permissions import HasPointyPermission
from .roles import ensure_role_groups
from .models import ShopSettings
from .serializers import (
    LoginSerializer,
    PosUserSerializer,
    ShopSettingsSerializer,
    UserSerializer,
)
from .user_activity import build_user_activity


SHOP_LOGO_ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png"}


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
        "activity": ("auth.view_user",),
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

    @action(detail=True, methods=["get"])
    def activity(self, request, pk=None):
        user = self.get_object()
        return Response(
            {
                "user": PosUserSerializer(user).data,
                **build_user_activity(user),
            }
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
        serializer = ShopSettingsSerializer(
            ShopSettings.load(),
            context={"request": request},
        )
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
                "prevent_selling_at_loss": settings.prevent_selling_at_loss,
                "auto_print_receipts": settings.auto_print_receipts,
                "require_opening_cash": settings.require_opening_cash,
                "cashier_return_window_hours": settings.cashier_return_window_hours,
                "low_stock_threshold": settings.low_stock_threshold,
                "enable_cash_payments": settings.enable_cash_payments,
                "enable_card_payments": settings.enable_card_payments,
                "enable_transfer_payments": settings.enable_transfer_payments,
            },
        )
        return Response(
            ShopSettingsSerializer(settings, context={"request": request}).data
        )


class ShopSettingsLogoView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]
    parser_classes = [parsers.MultiPartParser, parsers.FormParser]

    def get_required_permissions(self, request):
        return ("core.change_shopsettings",)

    def post(self, request):
        settings = ShopSettings.load()
        data = request.data.copy()
        uploaded_file = data.get("file")
        content_type = (
            content_type_for_upload(uploaded_file).lower() if uploaded_file else ""
        )
        if content_type not in SHOP_LOGO_ALLOWED_CONTENT_TYPES:
            return Response(
                {"file": ["Shop logo must be a PNG or JPEG image."]},
                status=status.HTTP_400_BAD_REQUEST,
            )
        data["role"] = Attachment.Role.SHOP_LOGO
        data["is_primary"] = True
        serializer = AttachmentSerializer(
            data=data,
            context={"request": request, "owner": settings},
        )
        serializer.is_valid(raise_exception=True)
        attachment = serializer.save()
        old_attachments = (
            active_attachments_for(settings, role=Attachment.Role.SHOP_LOGO)
            .exclude(pk=attachment.pk)
        )
        removed_count = 0
        for old_attachment in old_attachments:
            old_attachment.soft_delete(deleted_by=request.user)
            removed_count += 1
        record_domain_event(
            name="settings.shop.logo_uploaded",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="shop_settings",
            entity_id=settings.pk,
            attributes={
                "attachment_id": attachment.pk,
                "content_type": attachment.content_type,
                "original_size": attachment.original_size,
                "replaced_count": removed_count,
            },
        )
        return Response(
            ShopSettingsSerializer(settings, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )

    def delete(self, request):
        settings = ShopSettings.load()
        attachments = list(
            active_attachments_for(settings, role=Attachment.Role.SHOP_LOGO)
        )
        for attachment in attachments:
            attachment.soft_delete(deleted_by=request.user)
        record_domain_event(
            name="settings.shop.logo_removed",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="shop_settings",
            entity_id=settings.pk,
            attributes={"removed_count": len(attachments)},
        )
        return Response(
            ShopSettingsSerializer(settings, context={"request": request}).data
        )
