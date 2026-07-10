"""ModelBackend with the User row and resolved permission set memoised in Redis.

Stock ``ModelBackend`` resolves a user's permissions with two JOIN queries per
request (direct grants + group grants) the first time ``has_perm`` runs. The
set only changes when someone edits roles or grants, so we keep the resolved
``frozenset`` in Redis keyed by ``user_id + global permission version``; the
signals in ``signals.py`` bump the version on any permission-affecting change,
which instantly orphans every cached set.

``get_user`` — the SELECT the auth middleware runs for ``request.user`` on
every request — is cached the same way, invalidated by user save/delete
signals with a short TTL as the out-of-band-write backstop.

Fail-open: Redis trouble (or the caches being disabled, e.g. under tests) just
means falling through to ModelBackend's live queries.
"""

from django.contrib.auth.backends import ModelBackend

from apps.core import caching


class CachedPermissionsBackend(ModelBackend):
    def get_user(self, user_id):
        """The auth-middleware user fetch, from Redis when possible.

        With sessions and permissions already cached, this single SELECT on
        ``auth_user`` was the last DB query every authenticated request paid.
        The row is invalidated on every user save/delete (signals.py), and
        ``user_can_authenticate`` re-runs on each hit so a deactivation is
        honoured no later than its own invalidation signal.
        """
        cached = caching.get_cached_user(user_id)
        if cached is not None:
            return cached if self.user_can_authenticate(cached) else None
        user = super().get_user(user_id)
        if user is not None:
            caching.set_cached_user(user)
        return user

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
