from django.contrib.auth import get_user_model
from django.contrib.auth import login, logout, update_session_auth_hash
from django.middleware.csrf import get_token
from rest_framework import parsers, status, views, viewsets
from rest_framework.decorators import (
    action,
    api_view,
    permission_classes,
    throttle_classes,
)
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSerializer
from apps.attachments.services import active_attachments_for, content_type_for_upload

from .models import ShopSettings
from .permissions import HasPointyPermission
from .relay import relay_ai_available
from .roles import (
    create_initial_admin_user,
    ensure_role_groups,
    initial_admin_setup_required,
)
from .throttling import (
    LoginRateThrottle,
    LoginUsernameRateThrottle,
    PasswordChangeRateThrottle,
    SetupRateThrottle,
)
from .serializers import (
    CurrentUserUpdateSerializer,
    InitialAdminSetupSerializer,
    LoginSerializer,
    PasswordChangeSerializer,
    PosUserSerializer,
    ShopSettingsSerializer,
    ShopSetupSerializer,
    UserSerializer,
)
from .user_activity import build_user_activity


SHOP_LOGO_ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png"}


@api_view(["GET"])
@permission_classes([AllowAny])
def setup_status_view(request):
    return Response({"requires_onboarding": initial_admin_setup_required()})


@api_view(["POST"])
@permission_classes([AllowAny])
@throttle_classes([SetupRateThrottle])
def setup_initial_admin_view(request):
    if not initial_admin_setup_required():
        return Response(
            {"detail": "Initial setup has already been completed."},
            status=status.HTTP_409_CONFLICT,
        )

    serializer = InitialAdminSetupSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    admin = create_initial_admin_user(**serializer.validated_data)
    if admin is None:
        return Response(
            {"detail": "Initial setup has already been completed."},
            status=status.HTTP_409_CONFLICT,
        )

    from apps.employees.services import ensure_employee_for_user

    ensure_employee_for_user(admin, created_by=admin)
    login(request, admin)
    record_domain_event(
        name="setup.initial_admin.created",
        event_type=AnalyticsEvent.EventType.SECURITY,
        user=admin,
        entity_type="user",
        entity_id=admin.pk,
        attributes={"username": admin.username},
    )
    return Response(
        {"user": UserSerializer(admin).data, "csrf_token": get_token(request)},
        status=status.HTTP_201_CREATED,
    )


@api_view(["POST"])
@permission_classes([AllowAny])
@throttle_classes([LoginRateThrottle, LoginUsernameRateThrottle])
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
    return Response(
        {
            "user": UserSerializer(user).data,
            "csrf_token": get_token(request),
            "ai_available": relay_ai_available(),
        }
    )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def logout_view(request):
    logout(request)
    return Response(status=status.HTTP_204_NO_CONTENT)


@api_view(["GET", "PATCH"])
@permission_classes([IsAuthenticated])
def me_view(request):
    if request.method == "PATCH":
        serializer = CurrentUserUpdateSerializer(
            request.user,
            data=request.data,
            partial=True,
        )
        serializer.is_valid(raise_exception=True)
        before = {
            field: getattr(request.user, field)
            for field in serializer.validated_data
        }
        user = serializer.save()
        changed_fields = [
            field for field, previous in before.items() if getattr(user, field) != previous
        ]
        record_domain_event(
            name="auth.profile.updated",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=user,
            entity_type="user",
            entity_id=user.pk,
            attributes={"changed_fields": sorted(changed_fields)},
        )
        return Response(
            {
                "user": UserSerializer(user).data,
                "csrf_token": get_token(request),
                "ai_available": relay_ai_available(),
            }
        )
    return Response(
        {
            "user": UserSerializer(request.user).data,
            "csrf_token": get_token(request),
            "ai_available": relay_ai_available(),
        }
    )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
@throttle_classes([PasswordChangeRateThrottle])
def password_change_view(request):
    serializer = PasswordChangeSerializer(
        data=request.data,
        context={"request": request},
    )
    serializer.is_valid(raise_exception=True)
    user = serializer.save()
    update_session_auth_hash(request, user)
    record_domain_event(
        name="auth.password.changed",
        event_type=AnalyticsEvent.EventType.SECURITY,
        user=user,
        entity_type="user",
        entity_id=user.pk,
        attributes={"self_service": True},
    )
    return Response(status=status.HTTP_204_NO_CONTENT)


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
        from apps.employees.services import ensure_employee_for_user

        role = self.request.data.get("role", "")
        user = serializer.save()
        ensure_employee_for_user(user, created_by=self.request.user)
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
                "enable_online_invoices": settings.enable_online_invoices,
                "require_opening_cash": settings.require_opening_cash,
                "cashier_return_window_hours": settings.cashier_return_window_hours,
                "low_stock_threshold": settings.low_stock_threshold,
                "enable_cash_payments": settings.enable_cash_payments,
                "enable_card_payments": settings.enable_card_payments,
                "enable_transfer_payments": settings.enable_transfer_payments,
                "require_card_payment_receipt": (
                    settings.require_card_payment_receipt
                ),
                "trusted_card_terminal_count": len(
                    settings.trusted_card_terminal_ids or []
                ),
            },
        )
        return Response(
            ShopSettingsSerializer(settings, context={"request": request}).data
        )


class ShopSetupView(views.APIView):
    """First-run wizard: apply a shop-type preset plus the user's explicit
    choices in one shot, then record the chosen vertical."""

    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("core.change_shopsettings",)

    def post(self, request):
        serializer = ShopSetupSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        settings = ShopSettings.load()
        settings.apply_shop_type_preset(data["shop_type"])
        for field in (
            "shop_name",
            "allow_overselling",
            "require_opening_cash",
            "auto_print_receipts",
            "auto_print_kitchen_tickets",
        ):
            if field in data:
                setattr(settings, field, data[field])
        settings.save()

        record_domain_event(
            name="settings.shop.setup_completed",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=request.user,
            entity_type="shop_settings",
            entity_id=settings.pk,
            attributes={"shop_type": settings.shop_type},
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
        from apps.core.images import normalized_logo_upload

        settings = ShopSettings.load()
        # Never request.data.copy() here: QueryDict.copy() deep-copies the
        # upload, which fails for disk-buffered files (uploads over ~2.5MB).
        uploaded_file = request.data.get("file")
        content_type = (
            content_type_for_upload(uploaded_file).lower() if uploaded_file else ""
        )
        if content_type not in SHOP_LOGO_ALLOWED_CONTENT_TYPES:
            return Response(
                {"file": ["Shop logo must be a PNG or JPEG image."]},
                status=status.HTTP_400_BAD_REQUEST,
            )
        original_upload_size = getattr(uploaded_file, "size", 0)
        # Normalize so every stored logo fits the inline-embedding budget used
        # by thermal receipts and the public invoice page.
        normalized_file = normalized_logo_upload(uploaded_file, content_type)
        if normalized_file is None:
            return Response(
                {"file": ["Shop logo image could not be read."]},
                status=status.HTTP_400_BAD_REQUEST,
            )
        data = {
            "file": normalized_file,
            "role": Attachment.Role.SHOP_LOGO,
            "is_primary": True,
        }
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
                "uploaded_size": original_upload_size,
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
