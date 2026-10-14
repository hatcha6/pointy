"""The Moamalat link and live verification over HTTP.

    GET  /api/moamalat/status/    the link's state (details for supervisors)
    POST /api/moamalat/login/     {username, password} → OTP sent
    POST /api/moamalat/verify/    {challenge_id, code} → linked
    POST /api/moamalat/merchant/  {mid} → switch the merchant id
    POST /api/moamalat/unlink/    stop verifying, drop every copy
    POST /api/moamalat/watch/     {amount?, lookback_seconds?} a till's
                                  checkout is open: every unclaimed swipe since

Linking is the supervisor's (``payments.manage_moamalat_link``): the OTP goes to
the merchant's phone, and the shop — not Daftar — is the one logging in. A till
only ever watches.
"""

from datetime import timedelta
from decimal import Decimal, InvalidOperation

from django.db import transaction
from django.utils import timezone
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from . import cadence, custody, matching, watch

MANAGE = "payments.manage_moamalat_link"
#: How far back a watching till is shown the terminal's unclaimed swipes, by
#: default and at most.
WATCH_LOOKBACK = timedelta(minutes=15)
MAX_LOOKBACK_SECONDS = 30 * 60


def _link_error(exc: custody.LinkError) -> Response:
    code = status.HTTP_409_CONFLICT if exc.code == "switched_off" else status.HTTP_400_BAD_REQUEST
    return Response({"code": exc.code, "detail": exc.detail}, status=code)


def status_payload(link, *, can_manage: bool) -> dict:
    now = timezone.now()
    alive = link.state == link.State.ALIVE
    payload = {
        "linked": link.state != link.State.UNLINKED,
        "state": link.state,
        "at_risk": alive and cadence.at_risk(custody.age_of(link, now)),
        "switched_off": custody.switched_off(),
        "can_manage": can_manage,
    }
    if not can_manage:
        return payload
    pending = matching.pending_payments(link)
    payload.update(
        {
            "username": link.username,
            "mid": link.mid,
            "merchant_name": link.merchant_name,
            "linked_at": link.linked_at,
            "linked_by": getattr(link.linked_by, "username", "") if link.linked_by_id else "",
            "verify_since": link.verify_since,
            "last_ok_at": link.last_ok_at,
            "failures": link.failures,
            "last_error": link.last_error,
            "died_at": link.died_at,
            "death_source": link.death_source,
            "last_fetch_at": link.last_fetch_at,
            "last_fetch_error": link.last_fetch_error,
            "pending_count": pending.count(),
            "pending_overdue_count": pending.filter(paid_at__lt=now - timedelta(days=3)).count(),
            "relay": {
                "holds_copy": bool(link.relay_token_id),
                "in_step": bool(link.token_id) and link.relay_token_id == link.token_id,
                "state": link.relay_state,
                "last_ok_at": link.relay_last_ok_at,
                "checked_at": link.relay_checked_at,
                "error": link.relay_error,
            },
        }
    )
    return payload


class MoamalatViewSet(viewsets.ViewSet):
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        # Every signed-in user may read whether verification runs (a till shows
        # a quiet line when it does not); the details are trimmed below.
        "link_status": (),
        "login": (MANAGE,),
        "verify": (MANAGE,),
        "merchant": (MANAGE,),
        "unlink": (MANAGE,),
        "watch": ("payments.add_payment",),
    }

    def _can_manage(self, request) -> bool:
        return request.user.has_perm(MANAGE)

    @action(detail=False, methods=["get"], url_path="status")
    def link_status(self, request):
        return Response(status_payload(custody.load_link(), can_manage=self._can_manage(request)))

    @action(detail=False, methods=["post"])
    def login(self, request):
        try:
            answer = custody.start_link(
                str(request.data.get("username") or ""), str(request.data.get("password") or "")
            )
        except custody.LinkError as exc:
            return _link_error(exc)
        return Response(answer)

    @action(detail=False, methods=["post"])
    def verify(self, request):
        try:
            with transaction.atomic():
                answer = custody.complete_link(
                    str(request.data.get("challenge_id") or ""),
                    str(request.data.get("code") or ""),
                    user=request.user,
                )
        except custody.LinkError as exc:
            return _link_error(exc)
        answer["status"] = status_payload(custody.load_link(), can_manage=True)
        return Response(answer)

    @action(detail=False, methods=["post"])
    def merchant(self, request):
        try:
            with transaction.atomic():
                custody.choose_merchant(str(request.data.get("mid") or ""))
        except custody.LinkError as exc:
            return _link_error(exc)
        return Response(status_payload(custody.load_link(), can_manage=True))

    @action(detail=False, methods=["post"])
    def unlink(self, request):
        with transaction.atomic():
            custody.unlink()
        return Response(status_payload(custody.load_link(), can_manage=True))

    @action(detail=False, methods=["post"])
    def watch(self, request):
        """A till's payment sheet is open: keep the fast loop hot, and show
        the swipes the terminal took that no payment has claimed yet.

        Without ``amount`` every unclaimed swipe in the window comes back, so
        the till can see a swipe for the WRONG amount (and correct its tender)
        or one taken before the sheet opened. Rows are shown while resting too:
        the fast loop may be cooling down, but what was already read is real.
        """
        amount = None
        raw = request.data.get("amount")
        if raw not in (None, ""):
            try:
                amount = Decimal(str(raw))
            except (InvalidOperation, ValueError):
                amount = None
        # How far back to look: the till asks from a while before its sheet
        # opened, because a cashier may swipe the card before going to the
        # checkout. Bounded, so an old abandoned swipe is not offered forever.
        lookback = WATCH_LOOKBACK
        raw_lookback = request.data.get("lookback_seconds")
        if raw_lookback not in (None, ""):
            try:
                lookback = timedelta(seconds=min(max(int(raw_lookback), 60), MAX_LOOKBACK_SECONDS))
            except (TypeError, ValueError):
                lookback = WATCH_LOOKBACK
        watching = watch.heat(watch.HEARTBEAT_HOLDS)
        link = custody.load_link()
        rows = (
            matching.recent_unclaimed(since=timezone.now() - lookback, amount=amount)
            if link.state == link.State.ALIVE
            else []
        )
        payload = status_payload(link, can_manage=False)
        payload["watching"] = watching
        payload["last_fetch_at"] = link.last_fetch_at
        payload["transactions"] = [
            {
                "rrn": row.rrn,
                "terminal_id": row.terminal_id,
                "amount": f"{row.amount:.3f}",
                "transaction_at": row.transaction_at,
                "card_mask": row.card_mask,
            }
            for row in rows
        ]
        return Response(payload)
