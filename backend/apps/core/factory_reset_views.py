"""The endpoint behind the danger zone.

Two verbs, and the split matters. ``GET`` answers *what would go* — counted, in
the shop's own nouns — so the screen can put real numbers in front of the owner
before the dialog asks anything. ``POST`` does it. A destructive button whose
blast radius is only discoverable by pressing it is the one kind this codebase
refuses to build (see ``analytics.views.purge``, same rule).
"""

import logging

from django.contrib.auth import login, update_session_auth_hash
from django.middleware.csrf import get_token
from rest_framework import serializers, status, views
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

from .backup import latest_verified_backup
from .factory_reset import (
    FactoryResetError,
    invalidate_caches,
    perform_factory_reset,
    summarize,
)
from .models import ShopSettings
from .throttling import FactoryResetRateThrottle

logger = logging.getLogger(__name__)


class FactoryResetSerializer(serializers.Serializer):
    """Two proofs, deliberately of different kinds.

    The password proves *who* is asking — a till left unlocked at the counter
    is the realistic way this button gets pressed by the wrong person.

    The typed shop name proves *what* they think they are deleting. A shop that
    runs one backend for the workshop and another for the branch has two
    identical-looking apps, and "are you sure?" cannot tell them apart. Typing
    the name out is the only confirmation that carries information rather than
    reflex — the same reason GitHub asks for the repository name.
    """

    password = serializers.CharField(trim_whitespace=False, write_only=True)
    confirmation = serializers.CharField(write_only=True)

    def validate_password(self, value):
        user = self.context["request"].user
        if not user.check_password(value):
            raise serializers.ValidationError("كلمة المرور غير صحيحة.")
        return value

    def validate_confirmation(self, value):
        expected = (ShopSettings.load().shop_name or "").strip()
        if value.strip() != expected:
            raise serializers.ValidationError(
                f"اكتب اسم المتجر كما هو للتأكيد: {expected}"
            )
        return value


class FactoryResetView(views.APIView):
    """Owner-only. Not gated on a Django permission code, on purpose.

    Every other destructive action in the app hangs off a permission that a
    manager can be granted — and that is right for a refund, a void, even a
    telemetry purge. This one deletes the accounts themselves, including the
    accounts of whoever else could have stopped it, so it is restricted to a
    superuser: the account the first-run wizard creates and the only one that
    cannot be handed out by mistake from the users screen.
    """

    permission_classes = [IsAuthenticated]

    def get_throttles(self):
        if self.request.method == "POST":
            return [FactoryResetRateThrottle()]
        return super().get_throttles()

    def get(self, request):
        denied = self._refuse_unless_owner(request)
        if denied is not None:
            return denied
        return Response(self._preview(request))

    def post(self, request):
        denied = self._refuse_unless_owner(request)
        if denied is not None:
            return denied

        serializer = FactoryResetSerializer(data=request.data, context={"request": request})
        serializer.is_valid(raise_exception=True)

        admin = request.user
        try:
            summary = perform_factory_reset(admin=admin)
        except FactoryResetError as exception:
            return Response(
                {"detail": str(exception)}, status=status.HTTP_409_CONFLICT
            )

        # The truncate took django_session with it, so this request's own
        # session row no longer exists — every other device is now signed out,
        # which is the point (a till holding a catalogue of deleted products
        # must come back through the login screen). Signing the administrator
        # straight back in is what stops the screen that ran the reset from
        # bouncing to login before it can show what happened.
        admin.refresh_from_db()
        login(request, admin)
        update_session_auth_hash(request, admin)

        # No signals fired for a truncate, so nothing has invalidated itself.
        invalidate_caches()

        # Last, and into a table this call just emptied: erasing a shop's
        # history is itself the most auditable thing that can happen to it, and
        # this is the one row left to say who did it and how much went.
        record_domain_event(
            name="shop.factory_reset.completed",
            event_type=AnalyticsEvent.EventType.SECURITY,
            severity=AnalyticsEvent.Severity.WARNING,
            user=admin,
            entity_type="shop",
            attributes={"admin_username": summary.admin_username},
            metrics={
                "users_removed": summary.users_removed,
                **{f"deleted_{key}": value for key, value in summary.counts.items()},
            },
        )
        logger.warning(
            "factory reset completed by %s: %s", summary.admin_username, summary.counts
        )

        return Response(
            {**summary.as_dict(), "csrf_token": get_token(request)},
            status=status.HTTP_200_OK,
        )

    def _refuse_unless_owner(self, request):
        if request.user.is_superuser:
            return None
        return Response(
            {"detail": "هذا الإجراء متاح لحساب المالك فقط."},
            status=status.HTTP_403_FORBIDDEN,
        )

    def _preview(self, request):
        """Counts, plus the one fact that decides whether this is recoverable.

        The last verified backup is reported here rather than left to the
        screen to go and find, because it is the question an owner should be
        answering before they type their password and not after.
        """
        summary = summarize(admin=request.user)
        backup = latest_verified_backup()
        return {
            **summary.as_dict(),
            "shop_name": (ShopSettings.load().shop_name or "").strip(),
            "last_verified_backup_at": (
                backup.completed_at.isoformat()
                if backup is not None and backup.completed_at
                else None
            ),
        }
