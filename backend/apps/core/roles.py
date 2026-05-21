from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import IntegrityError, transaction
from django.utils.crypto import get_random_string

MANAGER_GROUP = "manager"
CASHIER_GROUP = "cashier"
ROLE_GROUPS = (MANAGER_GROUP, CASHIER_GROUP)

MANAGER_PERMISSION_DOMAINS = (
    "catalog",
    "core",
    "inventory",
    "sales",
    "customers",
    "discounts",
    "purchasing",
    "payments",
    "printing",
    "reports",
)
USER_PERMISSION_CODES = (
    "auth.add_user",
    "auth.change_user",
    "auth.delete_user",
    "auth.view_user",
)
CASHIER_PERMISSION_CODES = (
    "catalog.view_product",
    "catalog.view_productcategory",
    "sales.add_order",
    "sales.view_order",
    "sales.add_registersession",
    "sales.change_registersession",
    "sales.view_registersession",
    "sales.add_registercashmovement",
    "sales.view_registercashmovement",
    "payments.add_payment",
    "payments.view_payment",
    "core.view_shopsettings",
    "printing.add_printjob",
    "printing.change_printjob",
    "printing.view_printjob",
    "printing.view_printjobevent",
)


def _permissions_for_codes(permission_codes):
    permissions = []
    for permission_code in permission_codes:
        app_label, codename = permission_code.split(".", 1)
        permission = Permission.objects.filter(
            content_type__app_label=app_label,
            codename=codename,
        ).first()
        if permission is not None:
            permissions.append(permission)
    return permissions


def ensure_role_groups():
    groups = {
        role: Group.objects.get_or_create(name=role)[0]
        for role in ROLE_GROUPS
    }

    manager_permissions = Permission.objects.filter(
        content_type__app_label__in=MANAGER_PERMISSION_DOMAINS,
    )
    manager_user_permissions = _permissions_for_codes(USER_PERMISSION_CODES)
    cashier_permissions = _permissions_for_codes(CASHIER_PERMISSION_CODES)

    groups[MANAGER_GROUP].permissions.add(*manager_permissions, *manager_user_permissions)
    groups[CASHIER_GROUP].permissions.add(*cashier_permissions)
    return groups


def user_has_role(user, role):
    if not user or not user.is_authenticated:
        return False
    if user.is_superuser:
        return True
    return user.groups.filter(name=role).exists()


def user_is_manager(user):
    return user_has_role(user, MANAGER_GROUP)


def bootstrap_admin_user(*, username=None, email="", password=None, enabled=True):
    User = get_user_model()
    if not enabled:
        return None

    username = username or "admin"
    generated_password = None
    if password is None:
        generated_password = get_random_string(24)
        password = generated_password

    existing_user_count = User.objects.count()
    if existing_user_count:
        admin = User.objects.filter(username=username, is_superuser=True).first()
        if existing_user_count == 1 and admin is not None and not admin.has_usable_password():
            admin.set_password(password)
            admin.save(update_fields=["password"])
            admin._pointy_bootstrap_password = password
            admin._pointy_bootstrap_repaired = True
            return admin
        return None

    groups = ensure_role_groups()
    try:
        with transaction.atomic():
            admin = User.objects.create_superuser(
                username=username,
                email=email or "",
                password=password,
            )
    except IntegrityError:
        return None
    admin.groups.add(groups[MANAGER_GROUP])
    if generated_password is not None:
        admin._pointy_bootstrap_password = generated_password
    admin._pointy_bootstrap_created = True
    return admin
