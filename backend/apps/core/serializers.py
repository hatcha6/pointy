from django.contrib.auth import authenticate, get_user_model
from django.contrib.auth.password_validation import validate_password
from django.contrib.auth.models import Group
from rest_framework import serializers

from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSummarySerializer
from apps.attachments.services import active_attachments_for

from .models import ShopSettings
from .roles import ACCOUNTANT_GROUP, CASHIER_GROUP, MANAGER_GROUP, ROLE_GROUPS


class UserSerializer(serializers.ModelSerializer):
    role = serializers.SerializerMethodField()
    permissions = serializers.SerializerMethodField()

    class Meta:
        model = get_user_model()
        fields = [
            "id",
            "username",
            "email",
            "first_name",
            "last_name",
            "is_active",
            "role",
            "permissions",
        ]
        read_only_fields = ["id", "role", "permissions"]

    def get_role(self, user):
        if user.is_superuser or user.groups.filter(name=MANAGER_GROUP).exists():
            return MANAGER_GROUP
        if user.groups.filter(name=CASHIER_GROUP).exists():
            return CASHIER_GROUP
        if user.groups.filter(name=ACCOUNTANT_GROUP).exists():
            return ACCOUNTANT_GROUP
        return None

    def get_permissions(self, user):
        return sorted(user.get_all_permissions())


class LoginSerializer(serializers.Serializer):
    username = serializers.CharField()
    password = serializers.CharField(trim_whitespace=False, write_only=True)

    def validate(self, attrs):
        request = self.context.get("request")
        user = authenticate(
            request=request,
            username=attrs["username"],
            password=attrs["password"],
        )
        if user is None:
            raise serializers.ValidationError({"detail": "Invalid username or password."})
        if not user.is_active:
            raise serializers.ValidationError({"detail": "This user account is disabled."})
        attrs["user"] = user
        return attrs


class CurrentUserUpdateSerializer(serializers.ModelSerializer):
    class Meta:
        model = get_user_model()
        fields = ["username", "email", "first_name", "last_name"]

    def validate_username(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Username is required.")
        existing = get_user_model().objects.filter(username__iexact=value)
        if self.instance is not None:
            existing = existing.exclude(pk=self.instance.pk)
        if existing.exists():
            raise serializers.ValidationError("Username is already used.")
        return value


class PasswordChangeSerializer(serializers.Serializer):
    current_password = serializers.CharField(trim_whitespace=False, write_only=True)
    new_password = serializers.CharField(trim_whitespace=False, write_only=True)

    def validate_current_password(self, value):
        user = self.context["request"].user
        if not user.check_password(value):
            raise serializers.ValidationError("Current password is incorrect.")
        return value

    def validate_new_password(self, value):
        validate_password(value, self.context["request"].user)
        return value

    def save(self, **kwargs):
        user = self.context["request"].user
        user.set_password(self.validated_data["new_password"])
        user.save(update_fields=["password"])
        return user


class InitialAdminSetupSerializer(serializers.Serializer):
    username = serializers.CharField(max_length=150)
    email = serializers.EmailField(required=False, allow_blank=True)
    first_name = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=150,
    )
    last_name = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=150,
    )
    password = serializers.CharField(trim_whitespace=False, write_only=True)

    def validate_username(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Username is required.")
        return value

    def validate_email(self, value):
        return value.strip()

    def validate_first_name(self, value):
        return value.strip()

    def validate_last_name(self, value):
        return value.strip()

    def validate(self, attrs):
        User = get_user_model()
        user = User(
            username=attrs["username"],
            email=attrs.get("email", ""),
            first_name=attrs.get("first_name", ""),
            last_name=attrs.get("last_name", ""),
        )
        validate_password(attrs["password"], user)
        return attrs


class PosUserSerializer(serializers.ModelSerializer):
    role = serializers.ChoiceField(choices=ROLE_GROUPS, write_only=True)
    assigned_role = serializers.SerializerMethodField(read_only=True)
    password = serializers.CharField(write_only=True, required=False, allow_blank=False)

    class Meta:
        model = get_user_model()
        fields = [
            "id",
            "username",
            "email",
            "first_name",
            "last_name",
            "is_active",
            "role",
            "assigned_role",
            "password",
        ]
        read_only_fields = ["id", "assigned_role"]
        extra_kwargs = {"is_active": {"required": False}}

    def get_assigned_role(self, user):
        if user.groups.filter(name=MANAGER_GROUP).exists():
            return MANAGER_GROUP
        if user.groups.filter(name=CASHIER_GROUP).exists():
            return CASHIER_GROUP
        if user.groups.filter(name=ACCOUNTANT_GROUP).exists():
            return ACCOUNTANT_GROUP
        return None

    def validate_username(self, value):
        return value.strip()

    def validate(self, attrs):
        if self.instance is None and not attrs.get("password"):
            raise serializers.ValidationError({"password": "Password is required."})
        return attrs

    def _assign_role(self, user, role):
        role_groups = Group.objects.filter(name__in=ROLE_GROUPS)
        user.groups.remove(*role_groups)
        user.groups.add(Group.objects.get(name=role))

    def create(self, validated_data):
        role = validated_data.pop("role")
        password = validated_data.pop("password")
        user = get_user_model().objects.create_user(password=password, **validated_data)
        self._assign_role(user, role)
        return user

    def update(self, instance, validated_data):
        role = validated_data.pop("role", None)
        password = validated_data.pop("password", None)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        if password:
            instance.set_password(password)
        instance.save()
        if role:
            self._assign_role(instance, role)
        return instance


class ShopSettingsSerializer(serializers.ModelSerializer):
    logo_attachment = serializers.SerializerMethodField()

    def get_logo_attachment(self, settings):
        attachment = (
            active_attachments_for(settings, role=Attachment.Role.SHOP_LOGO)
            .filter(is_primary=True)
            .first()
        )
        if attachment is None:
            return None
        return AttachmentSummarySerializer(attachment, context=self.context).data

    def validate(self, attrs):
        settings = self.instance or ShopSettings.load()
        enable_cash = attrs.get("enable_cash_payments", settings.enable_cash_payments)
        enable_card = attrs.get("enable_card_payments", settings.enable_card_payments)
        enable_transfer = attrs.get(
            "enable_transfer_payments",
            settings.enable_transfer_payments,
        )
        if not any((enable_cash, enable_card, enable_transfer)):
            raise serializers.ValidationError(
                {"payment_methods": "At least one payment method must be enabled."}
            )
        return attrs

    def validate_trusted_card_terminal_ids(self, value):
        if not isinstance(value, list):
            raise serializers.ValidationError("Trusted terminal IDs must be a list.")
        normalized = []
        seen = set()
        for item in value:
            terminal_id = str(item).strip().upper()
            if not terminal_id:
                continue
            if terminal_id in seen:
                continue
            normalized.append(terminal_id)
            seen.add(terminal_id)
        return normalized

    class Meta:
        model = ShopSettings
        fields = [
            "shop_name",
            "receipt_header",
            "receipt_footer",
            "enable_online_invoices",
            "require_opening_cash",
            "auto_print_receipts",
            "allow_overselling",
            "prevent_selling_at_loss",
            "low_stock_threshold",
            "cashier_return_window_hours",
            "enable_cash_payments",
            "enable_card_payments",
            "enable_transfer_payments",
            "require_card_payment_receipt",
            "trusted_card_terminal_ids",
            "card_commission_percent",
            "transfer_commission_percent",
            "logo_attachment",
            "updated_at",
        ]
        read_only_fields = ["logo_attachment", "updated_at"]
