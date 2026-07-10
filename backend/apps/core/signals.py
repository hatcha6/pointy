from django.contrib.auth.models import Group, User
from django.db.models.signals import (
    m2m_changed,
    post_delete,
    post_migrate,
    post_save,
)
from django.dispatch import receiver

from . import caching
from .models import ShopSettings
from .roles import ensure_role_groups


@receiver(post_migrate)
def setup_auth_roles(sender, **kwargs):
    ensure_role_groups()


# --- ShopSettings singleton cache --------------------------------------------
# post_save also covers loaddata/admin (save_base fires it); bulk
# ``.filter(pk=1).update(...)`` is caught by ShopSettingsQuerySet.update().
@receiver(post_save, sender=ShopSettings)
@receiver(post_delete, sender=ShopSettings)
def invalidate_shop_settings_cache(sender, **kwargs):
    caching.invalidate_shop_settings()


# --- permission cache version -------------------------------------------------
# One global version stamp: any permission-affecting change orphans every cached
# per-user set (see apps.core.caching). Blunt, but these edits are rare and it
# keeps invalidation impossible to get wrong per-user.
@receiver(m2m_changed, sender=User.groups.through)
@receiver(m2m_changed, sender=User.user_permissions.through)
@receiver(m2m_changed, sender=Group.permissions.through)
def bump_perm_version_on_membership_change(sender, **kwargs):
    caching.bump_perm_version()


@receiver(post_save, sender=User)
def bump_perm_version_on_user_save(sender, instance, update_fields=None, **kwargs):
    # Login writes last_login on every session start — that never changes
    # permissions, so don't nuke the whole cache for it.
    if update_fields and set(update_fields) == {"last_login"}:
        return
    caching.bump_perm_version()


# Deleting a user or a group cascades the membership rows WITHOUT m2m_changed
# firing, so these need their own receivers.
@receiver(post_delete, sender=User)
@receiver(post_delete, sender=Group)
def bump_perm_version_on_delete(sender, **kwargs):
    caching.bump_perm_version()


# --- cached auth user row -------------------------------------------------------
# Unlike the permission version above, this one must fire on EVERY user save —
# a last_login-only save still changes the row the auth middleware serves.
@receiver(post_save, sender=User)
@receiver(post_delete, sender=User)
def invalidate_user_row_cache(sender, instance, **kwargs):
    caching.invalidate_user(instance.pk)
