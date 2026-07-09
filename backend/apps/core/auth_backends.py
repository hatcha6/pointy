"""ModelBackend with the resolved permission set memoised in Redis.

Stock ``ModelBackend`` resolves a user's permissions with two JOIN queries per
request (direct grants + group grants) the first time ``has_perm`` runs. The
set only changes when someone edits roles or grants, so we keep the resolved
``frozenset`` in Redis keyed by ``user_id + global permission version``; the
signals in ``signals.py`` bump the version on any permission-affecting change,
which instantly orphans every cached set.

Fail-open: Redis trouble (or the cache being disabled, e.g. under tests) just
means falling through to ModelBackend's live queries.
"""

from django.contrib.auth.backends import ModelBackend

from apps.core import caching


class CachedPermissionsBackend(ModelBackend):
    def get_all_permissions(self, user_obj, obj=None):
        if obj is not None or not user_obj.is_active or user_obj.is_anonymous:
            return super().get_all_permissions(user_obj, obj)
        # Per-instance memo first (mirrors ModelBackend's own _perm_cache), so
        # repeated has_perm calls in one request cost zero Redis round-trips.
        if not hasattr(user_obj, "_pointy_cached_perms"):
            perms = caching.get_cached_user_permissions(user_obj.pk)
            if perms is None:
                perms = frozenset(super().get_all_permissions(user_obj))
                caching.set_cached_user_permissions(user_obj.pk, perms)
            user_obj._pointy_cached_perms = perms
        return user_obj._pointy_cached_perms
