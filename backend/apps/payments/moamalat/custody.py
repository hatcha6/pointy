"""Holding the shop's Moamalat token: linking it, keeping it warm, sharing it.

Two holders keep the same token warm, independently, each on its own clock:
this backend (``keepalive_tick``, on Celery beat) and the relay (a sealed copy,
``relay/internal/relay/moamalat_keeper.go``). Any accepted call from either
resets the same server-side window, so two paths only add margin; neither
waits for the other. A token dies only on ``401 + oprationstate 6`` — whoever
sees it says so, and the other side learns it on its next read. Only the
shop's supervisor can bring it back (an OTP on the merchant's phone).

Every state change is compare-and-set on ``token_id``: a re-link mints a new
token while a call with the old one may still be in flight, and that call's 401
must not flip the healthy new link (``TOKEN_CUSTODY_DESIGN.md`` §State machine).
"""

from __future__ import annotations

import logging
import random
import secrets
from dataclasses import dataclass
from datetime import timedelta

from django.core.cache import cache
from django.db import transaction
from django.utils import timezone

from apps.core.secret_box import SecretBox

from . import cadence, portal

logger = logging.getLogger(__name__)

SECRET_BOX = SecretBox("POINTY_MOAMALAT_SECRET_KEY")
SWITCH_KEY = "moamalat"
#: An OTP challenge lives this long; Moamalat's own code expires sooner.
CHALLENGE_TTL = timedelta(minutes=5)
_CHALLENGE_KEY = "moamalat:challenge:{}"
_TICK_LOCK = "moamalat:tick"
#: How often the relay's copy is read back.
RELAY_CHECK_EVERY = timedelta(seconds=60)


class LinkError(Exception):
    """A link step the supervisor has to hear about. ``code`` is stable for
    the client; ``detail`` is Moamalat's own message when it sent one."""

    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


def load_link():
    from apps.payments.models import MoamalatLink

    link, _ = MoamalatLink.objects.get_or_create(pk=1)
    return link


def switched_off() -> bool:
    from apps.integrations.switches import is_switched_off

    return is_switched_off(SWITCH_KEY)


def token_of(link) -> str:
    return SECRET_BOX.decrypt(link.secrets_encrypted).get("token", "")


def _sealed(token: str) -> str:
    return SECRET_BOX.encrypt({"token": token}) if token else ""


def age_of(link, now=None):
    """Time since this backend's last accepted call (or since the link)."""
    now = now or timezone.now()
    since = link.last_ok_at or link.linked_at
    return now - since if since else timedelta(0)


# -- linking (the supervisor's two steps) ------------------------------------


def start_link(username: str, password: str) -> dict:
    """Send the merchant's username and password to Moamalat, which texts an
    OTP to the account's phone. Returns a challenge id for :func:`complete_link`.

    The password is passed through and forgotten: it is in no row, no cache,
    no log.
    """
    if switched_off():
        raise LinkError("switched_off")
    username = (username or "").strip()
    if not username or not password:
        raise LinkError("credentials_required")
    try:
        challenge, message = portal.start_login(username, password)
    except portal.PortalError as exc:
        raise LinkError("login_refused" if exc.status else "unreachable", exc.user_message) from exc
    challenge_id = secrets.token_urlsafe(16)
    _cache_set(
        _CHALLENGE_KEY.format(challenge_id),
        SECRET_BOX.encrypt({"challenge": challenge, "username": username}),
        int(CHALLENGE_TTL.total_seconds()),
    )
    return {"challenge_id": challenge_id, "message": message}


def complete_link(challenge_id: str, code: str, *, user=None) -> dict:
    """The OTP: trade the challenge for a token, keep it, hand it to the relay."""
    if switched_off():
        raise LinkError("switched_off")
    sealed = _cache_get(_CHALLENGE_KEY.format(challenge_id or ""))
    pending = SECRET_BOX.decrypt(sealed or "")
    if not pending.get("challenge"):
        raise LinkError("challenge_expired")
    code = (code or "").strip()
    if not code:
        raise LinkError("code_required")
    try:
        token = portal.verify_login(pending["challenge"], code)
        found = portal.merchants(token)
    except portal.PortalError as exc:
        raise LinkError("code_refused" if exc.status else "unreachable", exc.user_message) from exc
    _cache_delete(_CHALLENGE_KEY.format(challenge_id))
    if not found:
        raise LinkError("no_merchant")

    now = timezone.now()
    link = load_link()
    # Keep the merchant id the shop chose before, if this account still has it.
    chosen = next((m for m in found if m.mid == link.mid), None) or next(
        (m for m in found if m.owner), found[0]
    )
    link.username = pending.get("username", "")
    link.mid = chosen.mid
    link.merchant_name = chosen.name
    link.secrets_encrypted = _sealed(token)
    link.token_id = secrets.token_hex(16)
    link.state = link.State.ALIVE
    link.linked_by = user if getattr(user, "is_authenticated", False) else None
    link.linked_at = now
    link.verify_since = link.verify_since or now
    # Login and the merchant list were authenticated calls: the window is fresh.
    link.last_ok_at = now
    link.last_attempt_at = now
    link.failures = 0
    link.last_error = ""
    link.next_poke_at = now + cadence.next_after_success(_jitter())
    link.died_at = None
    link.death_source = ""
    link.save()
    token_id = link.token_id
    # The relay gets its copy as soon as the row is committed; the tick
    # retries if the relay is unreachable now. A re-link sweeps every payment
    # left pending while the token was dead.
    transaction.on_commit(lambda: _after_link(token_id))
    return {
        "state": link.state,
        "mid": link.mid,
        "merchant_name": link.merchant_name,
        "merchants": [{"mid": m.mid, "name": m.name, "owner": m.owner} for m in found],
    }


def _after_link(token_id):
    from apps.core.dispatch import enqueue_best_effort

    try:
        push_to_relay(load_link(), expected_token_id=token_id)
    except Exception:  # noqa: BLE001 - the tick retries; the link stands
        logger.warning("moamalat: relay hand-off after link failed", exc_info=True)
    enqueue_best_effort("payments.moamalat_sweep")


def choose_merchant(mid: str) -> dict:
    """Switch the linked account's merchant id — only to one the account
    itself lists right now (never an arbitrary id; ``API_CONTRACT.md`` §5)."""
    link = load_link()
    token = token_of(link)
    if link.state != link.State.ALIVE or not token:
        raise LinkError("not_linked")
    try:
        found = portal.merchants(token)
    except portal.PortalError as exc:
        if exc.outcome == portal.DEAD:
            mark_dead(link.token_id, "backend")
        raise LinkError("unreachable", exc.user_message) from exc
    chosen = next((m for m in found if m.mid == (mid or "").strip()), None)
    if chosen is None:
        raise LinkError("unknown_merchant")
    link.mid, link.merchant_name = chosen.mid, chosen.name
    link.last_ok_at = timezone.now()
    link.save(update_fields=["mid", "merchant_name", "last_ok_at", "updated_at"])
    token_id = link.token_id
    transaction.on_commit(lambda: push_to_relay(load_link(), expected_token_id=token_id, quiet=True))
    return {"mid": chosen.mid, "merchant_name": chosen.name}


def unlink(*, reason="") -> None:
    """Stop verifying: drop the token here and ask the relay to drop its copy.

    There is no logout endpoint; a token nobody pokes dies within 15 minutes.
    """
    link = load_link()
    link.state = link.State.UNLINKED
    link.secrets_encrypted = ""
    link.token_id = ""
    link.next_poke_at = None
    link.hot_until = None
    link.last_error = reason[:300]
    link.save()
    transaction.on_commit(lambda: delete_relay_copy(quiet=True))


# -- death ---------------------------------------------------------------------


def mark_dead(token_id: str, source: str) -> bool:
    """Move the link to NEEDS_REAUTH and drop the token — only if ``token_id``
    is still the one held. Returns whether it applied."""
    from apps.payments.models import MoamalatLink

    if not token_id:
        return False
    applied = MoamalatLink.objects.filter(
        pk=1, token_id=token_id, state=MoamalatLink.State.ALIVE
    ).update(
        state=MoamalatLink.State.NEEDS_REAUTH,
        secrets_encrypted="",
        died_at=timezone.now(),
        death_source=source,
        hot_until=None,
        updated_at=timezone.now(),
    )
    if applied:
        logger.warning("moamalat: token died (seen by %s); the shop must re-link", source)
        if source == "backend":
            transaction.on_commit(lambda: report_death_to_relay(token_id))
    return bool(applied)


# -- the backend's keepalive ---------------------------------------------------


@dataclass
class TickResult:
    poked: bool = False
    outcome: str = ""


def keepalive_tick(now=None, *, call=None) -> TickResult:
    """One beat of this backend's keepalive. Cheap when nothing is due.

    ``call`` is the authenticated call to make (default: the merchant list); a
    verification read passes itself in so it counts as the poke.
    """
    if not _cache_add(_TICK_LOCK, 1, 30):
        return TickResult()
    try:
        return _tick(now or timezone.now(), call)
    finally:
        _cache_delete(_TICK_LOCK)


def _tick(now, call) -> TickResult:
    link = load_link()
    if switched_off():
        if link.state != link.State.UNLINKED:
            # The kill switch: stop and delete the copy, here and at the relay.
            unlink(reason="switched_off")
        return TickResult()
    if link.state == link.State.UNLINKED and not link.relay_token_id:
        # Never linked, or unlinked and the relay's copy already deleted:
        # nothing to keep or reconcile, so no call to anyone.
        return TickResult()
    if link.state != link.State.ALIVE:
        sync_relay(link, now)
        return TickResult()
    result = TickResult()
    if link.next_poke_at is None or link.next_poke_at <= now:
        result = TickResult(poked=True, outcome=poke(link, call=call, now=now))
        link.refresh_from_db()
    sync_relay(link, now)
    return result


def poke(link, *, call=None, now=None) -> str:
    """One authenticated call with the held token, recorded on the link
    (compare-and-set on its token). Returns the outcome."""
    from apps.payments.models import MoamalatLink

    token, token_id = token_of(link), link.token_id
    if not token:
        return ""
    try:
        (call or portal.poke)(token)
    except portal.PortalError as exc:
        if exc.outcome == portal.DEAD:
            mark_dead(token_id, "backend")
            return portal.DEAD
        now = timezone.now()
        failures = link.failures + 1
        delay = cadence.next_after_failure(age_of(link, now), failures, exc.retry_after)
        MoamalatLink.objects.filter(pk=1, token_id=token_id, state=MoamalatLink.State.ALIVE).update(
            failures=failures,
            last_attempt_at=now,
            last_error=portal.describe(exc),
            next_poke_at=now + delay,
            updated_at=now,
        )
        logger.warning("moamalat: keepalive failed (%s), next try in %s", exc, delay)
        return portal.TRANSIENT
    note_accepted(token_id)
    return portal.ALIVE


def note_accepted(token_id: str) -> None:
    """Any accepted authenticated call resets the window: record it."""
    from apps.payments.models import MoamalatLink

    now = timezone.now()
    MoamalatLink.objects.filter(pk=1, token_id=token_id, state=MoamalatLink.State.ALIVE).update(
        last_ok_at=now,
        last_attempt_at=now,
        failures=0,
        last_error="",
        next_poke_at=now + cadence.next_after_success(_jitter()),
        updated_at=now,
    )


def _jitter() -> float:
    return random.uniform(-1.0, 1.0)  # noqa: S311 - spacing, not security


# -- the relay's copy ----------------------------------------------------------


def _relay_client():
    from apps.core.models import RelayInstallation
    from apps.core.relay import scoped_relay_client

    from django.core.exceptions import ImproperlyConfigured

    installation = RelayInstallation.load()
    if installation is None or not installation.access_token:
        return None, ""
    try:
        return scoped_relay_client(installation), installation.access_token
    except ImproperlyConfigured:
        # No relay configured: this backend keeps the token warm alone.
        return None, ""


def push_to_relay(link, *, expected_token_id="", quiet=False) -> bool:
    """Hand the relay the current token. False when there is no relay or it
    could not be reached (the tick tries again)."""
    from apps.core.relay import RelayControlError
    from apps.payments.models import MoamalatLink

    token = token_of(link)
    if link.state != link.State.ALIVE or not token or (
        expected_token_id and expected_token_id != link.token_id
    ):
        return False
    client, access_token = _relay_client()
    if client is None:
        return False
    try:
        answer = client.put_moamalat_link(
            access_token=access_token, mid=link.mid, token=token, token_id=link.token_id
        )
    except RelayControlError as exc:
        MoamalatLink.objects.filter(pk=1).update(relay_error=str(exc)[:300])
        if not quiet:
            logger.warning("moamalat: relay did not take the token: %s", exc)
        return False
    MoamalatLink.objects.filter(pk=1, token_id=link.token_id).update(
        relay_token_id=str(answer.get("token_id") or link.token_id),
        relay_state=str(answer.get("state") or ""),
        relay_checked_at=timezone.now(),
        relay_error="",
    )
    return True


def delete_relay_copy(*, quiet=False) -> bool:
    from apps.core.relay import RelayControlError
    from apps.payments.models import MoamalatLink

    client, access_token = _relay_client()
    if client is None:
        return False
    try:
        client.delete_moamalat_link(access_token=access_token)
    except RelayControlError as exc:
        MoamalatLink.objects.filter(pk=1).update(relay_error=str(exc)[:300])
        if not quiet:
            logger.warning("moamalat: relay copy not deleted: %s", exc)
        return False
    MoamalatLink.objects.filter(pk=1).update(
        relay_token_id="", relay_state="", relay_error="", relay_checked_at=timezone.now()
    )
    return True


def report_death_to_relay(token_id: str) -> None:
    from apps.core.relay import RelayControlError

    client, access_token = _relay_client()
    if client is None:
        return
    try:
        client.report_moamalat_dead(access_token=access_token, token_id=token_id)
    except RelayControlError as exc:
        # The relay finds out on its own next poke anyway.
        logger.info("moamalat: relay not told of the death: %s", exc)


def sync_relay(link, now=None) -> None:
    """Read the relay's copy back and reconcile, at most once a minute.

    - the relay holds no copy, or another token → hand it this one;
    - the relay saw THIS token die → so did we (compare-and-set);
    - the shop unlinked but the relay still holds a copy → delete it.
    """
    from apps.core.relay import RelayControlError
    from apps.payments.models import MoamalatLink

    now = now or timezone.now()
    if link.relay_checked_at and now - link.relay_checked_at < RELAY_CHECK_EVERY:
        return
    client, access_token = _relay_client()
    if client is None:
        return
    try:
        answer = client.moamalat_link(access_token=access_token)
    except RelayControlError as exc:
        status = getattr(exc, "status_code", None)
        MoamalatLink.objects.filter(pk=1).update(
            relay_checked_at=now,
            # 501: the relay has no Moamalat key; nothing is wrong here.
            relay_error="" if status in (404, 501) else str(exc)[:300],
        )
        return
    relay_linked = bool(answer.get("linked"))
    relay_token_id = str(answer.get("token_id") or "") if relay_linked else ""
    relay_state = str(answer.get("state") or "") if relay_linked else ""
    MoamalatLink.objects.filter(pk=1).update(
        relay_token_id=relay_token_id,
        relay_state=relay_state,
        relay_last_ok_at=_parse_time(answer.get("last_ok_at")),
        relay_checked_at=now,
        relay_error="",
    )
    if link.state == link.State.UNLINKED:
        if relay_linked:
            delete_relay_copy(quiet=True)
        return
    if link.state != link.State.ALIVE:
        return
    if relay_token_id == link.token_id and relay_state == "needs_reauth":
        mark_dead(link.token_id, "relay")
    elif relay_token_id != link.token_id or relay_state != "alive":
        push_to_relay(link, quiet=True)


def _parse_time(value):
    from django.utils.dateparse import parse_datetime

    if not value:
        return None
    try:
        return parse_datetime(str(value))
    except ValueError:
        return None


# -- cache, fail-open ----------------------------------------------------------
# Redis is short-lived state here (an OTP challenge, a lock). A Redis outage
# must cost a retry, never a crash in a Celery worker or a 500 at the counter.


def _cache_add(key, value, timeout) -> bool:
    try:
        return bool(cache.add(key, value, timeout))
    except Exception:  # noqa: BLE001
        return True


def _cache_set(key, value, timeout) -> None:
    try:
        cache.set(key, value, timeout)
    except Exception:  # noqa: BLE001
        logger.warning("moamalat: cache unavailable", exc_info=True)
        raise LinkError("unavailable") from None


def _cache_get(key):
    try:
        return cache.get(key)
    except Exception:  # noqa: BLE001
        return None


def _cache_delete(key) -> None:
    try:
        cache.delete(key)
    except Exception:  # noqa: BLE001
        pass
