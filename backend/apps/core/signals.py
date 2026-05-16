from django.conf import settings
from django.db.models.signals import post_migrate
from django.dispatch import receiver

from .roles import bootstrap_admin_user, ensure_role_groups


@receiver(post_migrate)
def setup_auth_roles(sender, **kwargs):
    ensure_role_groups()
    admin = bootstrap_admin_user(
        username=getattr(settings, "POINTY_BOOTSTRAP_ADMIN_USERNAME", "admin"),
        email=getattr(settings, "POINTY_BOOTSTRAP_ADMIN_EMAIL", ""),
        password=getattr(settings, "POINTY_BOOTSTRAP_ADMIN_PASSWORD", None),
        enabled=getattr(settings, "POINTY_BOOTSTRAP_ADMIN_ENABLED", True),
    )
    generated_password = getattr(admin, "_pointy_bootstrap_password", None)
    stdout = kwargs.get("stdout")
    if generated_password and stdout:
        action = "Repaired" if getattr(admin, "_pointy_bootstrap_repaired", False) else "Created"
        stdout.write(f"{action} bootstrap admin user '{admin.username}'.")
        stdout.write(f"Bootstrap admin password: {generated_password}")
