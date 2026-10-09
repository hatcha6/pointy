"""Operator logos on the direct top-up screen, kept in the shop's own storage.

The relay never hands a shop the supplier's logo URL (that would name the
supplier): it copies each logo and names the copy by its hash
(``sha256:<hex>``). This module mirrors those copies the way
:mod:`.voucher_flags` mirrors the card shelf's flags — fetched once from the
relay, shrunk to a small PNG, kept in :class:`IntegrationServiceLogo` — and the
menu points tills at the shop backend alone
(``/api/integrations/services/logos/<hex>/``, see :func:`url_for`).

A hash names one picture for ever, so a stored logo is never asked for again; one
that did not come (the relay has not copied it yet, a 404) is asked for again an
hour later.
"""

from __future__ import annotations

import logging
import re

from django.utils import timezone

from .models import IntegrationServiceCountry, IntegrationServiceLogo
from .providers import provider_for
from .voucher_flags import FLAG_RETRY_AFTER, flag_ready

logger = logging.getLogger(__name__)

#: Logos one sweep may fetch.
LOGOS_PER_SWEEP = 64
PATH = re.compile(r"sha256:([0-9a-f]{64})")
URL_PREFIX = "/api/integrations/services/logos/"


def wanted_paths(account) -> list[str]:
    """Every logo path the mirrored operators name, in the directory's order."""
    seen: dict[str, None] = {}
    for row in IntegrationServiceCountry.objects.filter(account=account).only("payload"):
        for operator in ((row.payload or {}).get("airtime") or {}).get("operators") or ():
            path = str(operator.get("logo") or "")
            if PATH.fullmatch(path):
                seen[path] = None
    return list(seen)


def sync_logos(account, *, limit: int = LOGOS_PER_SWEEP) -> int:
    """Fetch the logos that are due, on this thread. Returns how many came in."""
    wanted = wanted_paths(account)
    if not wanted:
        return 0
    now = timezone.now()
    known = {
        row.path: row
        for row in IntegrationServiceLogo.objects.filter(account=account).defer("picture")
    }
    due = []
    for path in wanted:
        row = known.get(path)
        if (
            row is None
            or (row.checked_at is None or row.checked_at < now - FLAG_RETRY_AFTER)
            and not _has_picture(account, path)
        ):
            due.append(path)
    stored = 0
    driver = None
    for path in due[:limit]:
        driver = driver or provider_for(account)
        logo = driver.voucher_logo(path)
        picture = flag_ready(logo.data) if logo.ok else None
        if picture is None:
            logger.info(
                "no logo for %s (%s): %s",
                account.provider,
                path,
                logo.error_detail or "not an image",
            )
            IntegrationServiceLogo.objects.update_or_create(
                account=account, path=path, defaults={"checked_at": now}
            )
            continue
        IntegrationServiceLogo.objects.update_or_create(
            account=account, path=path, defaults={"picture": picture, "checked_at": now}
        )
        stored += 1
    return stored


def _has_picture(account, path: str) -> bool:
    return IntegrationServiceLogo.objects.filter(
        account=account, path=path, picture__isnull=False
    ).exists()


def available(account) -> frozenset[str]:
    """The paths whose picture the shop holds."""
    return frozenset(
        IntegrationServiceLogo.objects.filter(account=account, picture__isnull=False).values_list(
            "path", flat=True
        )
    )


def url_for(path: str, held: frozenset[str]) -> str:
    """The shop's own address of a logo, ``""`` while it is not held."""
    return f"{URL_PREFIX}{path[len('sha256:') :]}/" if path in held else ""


def picture_for(digest: str) -> bytes | None:
    """The PNG of a logo by its hash, from whichever account holds it."""
    row = (
        IntegrationServiceLogo.objects.filter(path=f"sha256:{digest}", picture__isnull=False)
        .only("picture")
        .first()
    )
    return bytes(row.picture) if row and row.picture else None
