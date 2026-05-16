from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.contrib.contenttypes.models import ContentType
from django.db import IntegrityError, transaction
from django.utils.crypto import get_random_string

MANAGER_GROUP = "manager"
CASHIER_GROUP = "cashier"
ROLE_GROUPS = (MANAGER_GROUP, CASHIER_GROUP)


def ensure_role_groups():
    groups = {
        role: Group.objects.get_or_create(name=role)[0]
        for role in ROLE_GROUPS
    }

    user_content_type = ContentType.objects.get_for_model(get_user_model())
    user_permissions = Permission.objects.filter(
        content_type=user_content_type,
        codename__in=("add_user", "change_user", "delete_user", "view_user"),
    )
    groups[MANAGER_GROUP].permissions.add(*user_permissions)
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
