from django.contrib.auth import authenticate, get_user_model
from django.contrib.auth.password_validation import validate_password
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db.models import Q
from rest_framework import serializers

from apps.fx import currencies as fx_currencies
from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSummarySerializer
from apps.attachments.services import active_attachments_for

from .models import ShopSettings
from .password_policy import password_error_codes
from .permission_catalog import catalog_codes, grantable_for
from .roles import (
    ROLE_GROUPS,
    assigned_role_from_group_names,
    role_permission_codes,
)


def _permission_objects_for_codes(codes):
    """Resolve ``app_label.codename`` strings to Permission rows in one query."""
    pairs = [code.split(".", 1) for code in codes if "." in code]
    if not pairs:
        return []
    query = Q()
    for app_label, codename in pairs:
        query |= Q(content_type__app_label=app_label, codename=codename)
    return list(Permission.objects.filter(query))


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
        return assigned_role_from_group_names(
            {group.name for group in user.groups.all()},
            is_superuser=user.is_superuser,
        )

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

    def validate(self, attrs):
        # Object-level, not field-level: a field validator's error is nested
        # under its own key, and the machine codes have to sit at the top of the
        # body where the client reads them.
        try:
            validate_password(attrs["new_password"], self.context["request"].user)
        except DjangoValidationError as exc:
            raise serializers.ValidationError(
                {
                    "new_password": list(exc.messages),
                    "codes": password_error_codes(exc),
                }
            ) from exc
        return attrs

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


# Sentinel so an absent ``extra_permissions`` (no change) is distinguishable from
# an explicit empty list (revoke all extras).
_EXTRAS_UNSET = object()


class PosUserSerializer(serializers.ModelSerializer):
    role = serializers.ChoiceField(
        choices=ROLE_GROUPS, write_only=True, required=False
    )
    assigned_role = serializers.SerializerMethodField(read_only=True)
    password = serializers.CharField(write_only=True, required=False, allow_blank=False)
    # Directly-granted permissions, additive on top of the role. Write a full
    # desired set (replace semantics); read back via to_representation.
    extra_permissions = serializers.ListField(
        child=serializers.CharField(),
        required=False,
        write_only=True,
    )
    role_permissions = serializers.SerializerMethodField()
    effective_permissions = serializers.SerializerMethodField()
    extra_permission_count = serializers.SerializerMethodField()

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
            "extra_permissions",
            "role_permissions",
            "effective_permissions",
            "extra_permission_count",
        ]
        read_only_fields = [
            "id",
            "assigned_role",
            "role_permissions",
            "effective_permissions",
            "extra_permission_count",
        ]
        extra_kwargs = {"is_active": {"required": False}}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # The list view only needs enough for the row badges; the full
        # per-permission breakdown is reserved for retrieve/activity so listing
        # users stays cheap.
        if getattr(self.context.get("view"), "action", None) == "list":
            self.fields.pop("role_permissions", None)
            self.fields.pop("effective_permissions", None)

    # -- role resolution (uses prefetched groups; no per-row query) -----------
    def _resolved_role(self, user):
        cached = getattr(user, "_pointy_role_cache", None)
        if cached is None:
            cached = assigned_role_from_group_names(
                {group.name for group in user.groups.all()},
                is_superuser=user.is_superuser,
            )
            user._pointy_role_cache = cached
        return cached

    @staticmethod
    def _extra_permission_codes(user):
        return sorted(
            f"{perm.content_type.app_label}.{perm.codename}"
            for perm in user.user_permissions.all()
        )

    def get_assigned_role(self, user):
        return self._resolved_role(user)

    def get_role_permissions(self, user):
        codes = role_permission_codes(self._resolved_role(user))
        return ["*"] if codes is None else sorted(codes)

    def get_effective_permissions(self, user):
        codes = role_permission_codes(self._resolved_role(user))
        if codes is None:
            return ["*"]
        return sorted(set(codes) | set(self._extra_permission_codes(user)))

    def get_extra_permission_count(self, user):
        return len(self._extra_permission_codes(user))

    def to_representation(self, instance):
        data = super().to_representation(instance)
        if getattr(self.context.get("view"), "action", None) != "list":
            data["extra_permissions"] = self._extra_permission_codes(instance)
        return data

    # -- validation -----------------------------------------------------------
    def validate_username(self, value):
        return value.strip()

    # A role is a bundle of permissions and every field on this serializer can
    # hand control of an account over, so both are bound by the same rule that
    # already governs ``extra_permissions``: an actor may only grant what they
    # hold themselves. In the default configuration only managers can manage
    # users at all, and a manager holds everything, so these guards bite only
    # once ``auth.add_user`` / ``auth.change_user`` has been delegated to a
    # narrower role — which is exactly when they are needed.
    def _actor(self):
        return getattr(self.context.get("request"), "user", None)

    def _holds_every_permission(self, user):
        """True for a manager or superuser — ``role_permission_codes`` reports
        their role as unbounded, so there is nothing left to escalate to."""
        return role_permission_codes(self._resolved_role(user)) is None

    def _effective_permission_codes(self, user):
        """Every code ``user`` holds, or ``None`` when they hold all of them."""
        role_codes = role_permission_codes(self._resolved_role(user))
        if role_codes is None:
            return None
        return set(role_codes) | set(self._extra_permission_codes(user))

    def validate_role(self, value):
        actor = self._actor()
        if actor is None or self._holds_every_permission(actor):
            return value
        role_codes = role_permission_codes(value)
        if role_codes is None or not set(role_codes) <= actor.get_all_permissions():
            raise serializers.ValidationError(
                "You can only assign a role whose permissions you hold yourself."
            )
        return value

    def validate_extra_permissions(self, value):
        codes, seen = [], set()
        for raw in value:
            code = str(raw).strip()
            if code and code not in seen:
                seen.add(code)
                codes.append(code)
        allowed = catalog_codes()
        invalid = sorted(code for code in codes if code not in allowed)
        if invalid:
            raise serializers.ValidationError(
                "These permissions cannot be granted: " + ", ".join(invalid) + "."
            )
        # No privilege escalation: an admin may only grant permissions they
        # themselves hold (superusers excepted). Applies to editing oneself too.
        actor = getattr(self.context.get("request"), "user", None)
        if actor is not None and not actor.is_superuser:
            grantable = grantable_for(actor)
            escalated = sorted(code for code in codes if code not in grantable)
            if escalated:
                raise serializers.ValidationError(
                    "You can only grant permissions you hold yourself: "
                    + ", ".join(escalated)
                    + "."
                )
        return codes

    def validate(self, attrs):
        if self.instance is None and not attrs.get("password"):
            raise serializers.ValidationError({"password": "Password is required."})
        if self.instance is None and not attrs.get("role"):
            raise serializers.ValidationError({"role": "Role is required."})
        # Editing a more privileged account is escalation by another route: the
        # password field alone would let a delegate take a manager's account
        # over and log in as them.
        actor = self._actor()
        if (
            self.instance is not None
            and actor is not None
            and not self._holds_every_permission(actor)
        ):
            target_codes = self._effective_permission_codes(self.instance)
            if target_codes is None or not target_codes <= actor.get_all_permissions():
                raise serializers.ValidationError(
                    "You cannot edit a user who holds permissions you do not."
                )
        return attrs

    # -- persistence ----------------------------------------------------------
    def _assign_role(self, user, role):
        role_groups = Group.objects.filter(name__in=ROLE_GROUPS)
        user.groups.remove(*role_groups)
        user.groups.add(Group.objects.get(name=role))
        # Group membership changed: drop the per-instance role cache.
        if hasattr(user, "_pointy_role_cache"):
            del user._pointy_role_cache

    def _apply_extra_permissions(self, user, codes):
        """Set direct grants to exactly ``codes`` minus anything the role already
        covers. Managers hold everything, so their extras are always cleared."""
        role_codes = role_permission_codes(self._resolved_role(user))
        if role_codes is None:
            user.user_permissions.clear()
            return
        desired = {code for code in codes if code not in role_codes}
        user.user_permissions.set(_permission_objects_for_codes(desired))

    def _reconcile_extra_permissions(self, user):
        """After a role change with no explicit extras, drop extras the new role
        now covers (and clear all when promoted to manager)."""
        role_codes = role_permission_codes(self._resolved_role(user))
        if role_codes is None:
            user.user_permissions.clear()
            return
        redundant = set(self._extra_permission_codes(user)) & set(role_codes)
        if redundant:
            user.user_permissions.remove(*_permission_objects_for_codes(redundant))

    def create(self, validated_data):
        role = validated_data.pop("role")
        password = validated_data.pop("password")
        extra_permissions = validated_data.pop("extra_permissions", None)
        user = get_user_model().objects.create_user(password=password, **validated_data)
        self._assign_role(user, role)
        if extra_permissions is not None:
            self._apply_extra_permissions(user, extra_permissions)
        return user

    def update(self, instance, validated_data):
        role = validated_data.pop("role", None)
        password = validated_data.pop("password", None)
        extra_permissions = validated_data.pop("extra_permissions", _EXTRAS_UNSET)
        for field, value in validated_data.items():
            setattr(instance, field, value)
        if password:
            instance.set_password(password)
        instance.save()
        if role:
            self._assign_role(instance, role)
        if extra_permissions is not _EXTRAS_UNSET:
            self._apply_extra_permissions(instance, extra_permissions)
        elif role:
            self._reconcile_extra_permissions(instance)
        return instance


class ShopSettingsSerializer(serializers.ModelSerializer):
    logo_attachment = serializers.SerializerMethodField()
    # The shop's default credit terms, resolved — including the due date they
    # produce for an invoice issued today. The till proposes that date for a
    # walk-in آجل sale (a customer's own terms come back on the customer), so
    # the calendar arithmetic stays on one side of the wire.
    default_payment_terms = serializers.SerializerMethodField()

    def get_default_payment_terms(self, settings) -> dict:
        from apps.core.timeutils import business_local_date
        from apps.customers.payment_terms import shop_payment_terms

        terms = shop_payment_terms(settings)
        return {
            "days": terms.days,
            "basis": terms.basis,
            "is_immediate": terms.is_immediate,
            "due_date_for_today": terms.due_date_for(business_local_date()).isoformat(),
        }

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
        self._validate_valuation_method_change(attrs)
        return attrs

    def _validate_valuation_method_change(self, attrs):
        """Refuse a mid-life change of valuation method unless it is confirmed.

        The method decides what every past sale's cost *was*, so switching it
        re-labels history that has already been reported and paid commission
        against. A shop that has never moved stock has nothing to re-label and
        may switch freely; once stock has moved, the change needs an explicit
        acknowledgement so a client that forgets to show the warning cannot slip
        it through.
        """
        acknowledged = attrs.pop("valuation_method_change_acknowledged", False)
        method = attrs.get("inventory_valuation_method")
        if method is None or self.instance is None:
            return
        if method == self.instance.inventory_valuation_method:
            return
        if acknowledged or not shop_has_stock_history():
            return

        # DRF normalises every leaf of a ``validate()`` error to a list, so the
        # client reads ``code[0]`` to decide whether to raise the warning dialog.
        raise serializers.ValidationError(
            {
                "inventory_valuation_method": (
                    "Changing how stock is costed affects the recorded cost and "
                    "profit of sales that have already happened. Confirm the "
                    "change to continue."
                ),
                "code": "valuation_method_change_requires_acknowledgement",
                "current_method": self.instance.inventory_valuation_method,
                "requested_method": method,
            }
        )

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

    # Write-only escape hatch for the valuation-method guard below. The client
    # sets it only after the user has read the warning dialog and chosen to
    # continue anyway.
    valuation_method_change_acknowledged = serializers.BooleanField(
        write_only=True,
        required=False,
        default=False,
    )

    class Meta:
        model = ShopSettings
        fields = [
            "shop_name",
            "shop_phone",
            "shop_type",
            "currency_code",
            "currency_symbol",
            "receipt_header",
            "receipt_footer",
            "enable_online_invoices",
            "enable_repair_operations",
            "enable_production_operations",
            "enable_kitchen_operations",
            "kitchen_auto_complete",
            "enable_job_tracking",
            "require_opening_cash",
            "auto_print_receipts",
            # Auto-print floor — a sale prints by itself once it clears either.
            "auto_print_min_line_count",
            "auto_print_min_total",
            "auto_print_kitchen_tickets",
            "allow_overselling",
            "prevent_selling_at_loss",
            "low_stock_threshold",
            "warn_low_stock_before_sale",
            "inventory_valuation_method",
            # Accounting calendar. The fiscal year anchors the "this year" /
            # "last year" report presets; the lock date closes a period that has
            # already been reported.
            "fiscal_year_start_month",
            "books_locked_through",
            "month_end_snapshot_day",
            "month_end_report_phone",
            "stock_count_variance_min_units",
            "stock_count_variance_percent",
            "cashier_return_window_hours",
            "enable_cash_payments",
            "enable_card_payments",
            "enable_transfer_payments",
            "require_card_payment_receipt",
            "trusted_card_terminal_ids",
            "card_commission_percent",
            "transfer_commission_percent",
            "require_customer_for_credit",
            "enforce_customer_credit_limits",
            "default_customer_credit_limit",
            "default_payment_terms_days",
            "default_payment_terms_basis",
            "default_payment_terms",
            "allow_cashier_customer_access",
            "pos_cash_purchase_limit",
            "enable_purchase_suggestions",
            # Cameras. Gates every surveillance surface in the client; the
            # backend turns it on the first time a recorder connects.
            "enable_surveillance",
            "surveillance_pre_roll_seconds",
            "surveillance_post_roll_seconds",
            # Multi-currency. Off by default: a shop with no foreign exposure
            # never sees a currency picker anywhere in the app.
            "fx_enabled",
            "fx_instrument",
            "fx_bank_code",
            "fx_rate_staleness_hours",
            "fx_manual_only",
            "logo_attachment",
            "updated_at",
            "valuation_method_change_acknowledged",
            # Identified stock. The master switches shipped with Phase A as
            # columns nothing could edit; a shop entering a serialized or
            # lot-tracked trade turns them on here.
            "enable_serialized_inventory",
            "enable_batch_tracking",
            "serialized_capture_later_allowed",
            "serialized_require_customer_for_asset",
            "prevent_selling_expired_batches",
            "batch_auto_pick_strategy",
            "default_expiry_warning_days",
            # الأمانات. The three clauses are the contract, not a label derived
            # from the enum — a shop with a lawyer pastes its own words in, and
            # each signed agreement keeps the wording it was printed with.
            "consignment_auto_sms_on_sale",
            "consignment_default_liability_policy",
            "consignment_clause_owner_risk",
            "consignment_clause_shop_liable_except_fm",
            "consignment_clause_shop_liable",
            "consignment_require_declared_value",
            "consignment_unclaimed_payout_reminder_days",
            "consignment_sale_sms_template",
        ]
        # ``books_locked_through`` is read-only here on purpose: closing a
        # period is a bookkeeping act with its own permission and its own audit
        # trail, not a checkbox on the settings screen. It is written through
        # ``/api/reports/period-lock/`` (see apps.reports.views).
        # The accounting calendar — the fiscal year the reports anchor to and
        # the date the books are closed through — is read-only here on purpose.
        # Both are bookkeeping acts with their own permission and their own
        # audit trail, not checkboxes next to the receipt footer, and the people
        # who should be setting them (accountants, auditors) deliberately do not
        # hold ``core.change_shopsettings``. They are written through
        # ``/api/reports/period-lock/`` (see apps.reports.views).
        read_only_fields = [
            "shop_type",
            "fiscal_year_start_month",
            "books_locked_through",
            "month_end_snapshot_day",
            "month_end_report_phone",
            "month_end_snapshot_day",
            "month_end_report_phone",
            "logo_attachment",
            "default_payment_terms",
            "updated_at",
        ]



def shop_has_stock_history() -> bool:
    """Has any stock ever moved in this shop?

    Imported lazily: ``apps.inventory`` imports ``apps.core.models``, so a
    module-level import here would close the cycle.
    """
    from apps.inventory.models import StockMovement

    return StockMovement.objects.exists()


class ShopSetupSerializer(serializers.Serializer):
    """First-run wizard input: the chosen vertical plus the few settings the
    wizard exposes directly. Everything else comes from the preset."""

    shop_type = serializers.ChoiceField(choices=ShopSettings.ShopType.choices)
    shop_name = serializers.CharField(max_length=120, required=False)
    # Asked during setup because it is the one choice here that is expensive to
    # revisit: it decides what every future sale's cost will be.
    inventory_valuation_method = serializers.ChoiceField(
        choices=ShopSettings.ValuationMethod.choices,
        required=False,
    )
    allow_overselling = serializers.BooleanField(required=False)
    require_opening_cash = serializers.BooleanField(required=False)
    auto_print_receipts = serializers.BooleanField(required=False)
    auto_print_kitchen_tickets = serializers.BooleanField(required=False)
    # Whether the kitchen works off a printed chit (the default: the job is
    # finished at the sale) or off a screen (the staged
    # received→preparing→ready→served lane a pickup counter needs).
    kitchen_auto_complete = serializers.BooleanField(required=False)
    # Multi-currency, asked once at setup. Off is the right answer for the
    # overwhelming majority of Libyan shops — they buy and sell in dinars — so
    # the wizard asks a plain yes/no rather than presenting a currency matrix,
    # and everything stays single-currency unless the owner says otherwise.
    fx_enabled = serializers.BooleanField(required=False)
    # How the shop pays for foreign goods, when it has any. Both values are
    # parallel-market rates; see apps.fx.currencies.
    fx_instrument = serializers.ChoiceField(
        choices=fx_currencies.INSTRUMENTS,
        required=False,
    )
    fx_bank_code = serializers.CharField(
        max_length=32, required=False, allow_blank=True
    )
