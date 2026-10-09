"""The store regions' flags on the company's own shelf («كروت دفتر»).

iTunes US is not iTunes UK, and the till says which with a flag beside the
region's name. Emoji flags do not render on the Windows tills, so the operator
uploads a picture per region and the relay names it by its hash
(``sha256:<hex>``). Each one is fetched once, shrunk to a small PNG and kept on
the region's row, so the menu carries it inline and a till never downloads one.

A hash names one picture for ever: a region whose path has not changed is never
asked for again, and an unchanged shelf writes nothing here. A picture that
does not come (a 404, the relay unreachable) is asked for again an hour later.
"""

from __future__ import annotations

import io
import logging
from datetime import timedelta

from django.db.models import F, Q
from django.utils import timezone
from PIL import Image, ImageOps, UnidentifiedImageError
from PIL.Image import DecompressionBombError

from .models import IntegrationVoucherCountry
from .providers import provider_for

logger = logging.getLogger(__name__)

#: A flag is drawn beside a region's name on a chip: 96 px is generous for it
#: on any till, and small enough (a few KB) to ride inline in the menu.
FLAG_MAX_DIMENSION = 96
#: A flag that did not come is asked for again this long after the last try.
FLAG_RETRY_AFTER = timedelta(hours=1)
#: Flags one sweep may fetch. The company's catalog lists every country, so a shop
#: takes a few sweeps to hold them all; the regions the shelf uses come first (the
#: catalog's own order, ``rank``), so a till never waits for a flag it shows.
FLAGS_PER_SWEEP = 64


def sync_flags(account, *, limit: int = FLAGS_PER_SWEEP, model=IntegrationVoucherCountry) -> int:
    """Fetch the flags that are due, on this thread. Returns how many changed.

    ``model`` is the table whose countries are being given their flags: the
    shelf's store regions (the default) or the services directory's countries
    (``IntegrationServiceCountry``, see ``services_sync``). They keep the same
    four columns for it, and a ``rank`` the sweep fetches in the order of.
    """
    now = timezone.now()
    due = list(
        model.objects.filter(account=account)
        .exclude(flag_path=F("flag_source"))
        .filter(
            Q(flag_checked_at__isnull=True)
            | Q(flag_checked_at__lt=now - FLAG_RETRY_AFTER)
            | Q(flag_path="")
        )
        .defer("flag")
        .order_by(F("flag_checked_at").asc(nulls_first=True), "rank", "pk")[:limit]
    )
    if not due:
        return 0
    driver = None
    changed = 0
    for row in due:
        if not row.flag_path:
            # The region lost its flag: the menu shows its name alone.
            model.objects.filter(pk=row.pk).update(
                flag=None, flag_source="", flag_checked_at=now, updated_at=now
            )
            changed += 1
            continue
        driver = driver or provider_for(account)
        logo = driver.voucher_logo(row.flag_path)
        picture = flag_ready(logo.data) if logo.ok else None
        if picture is None:
            logger.info(
                "no flag for %s region %s (%s): %s",
                account.provider,
                row.code,
                row.flag_path,
                logo.error_detail or "not an image",
            )
            model.objects.filter(pk=row.pk, flag_path=row.flag_path).update(
                flag_checked_at=now, updated_at=now
            )
            continue
        # Only if the relay still names that picture: another one is due next.
        changed += model.objects.filter(pk=row.pk, flag_path=row.flag_path).update(
            flag=picture, flag_source=row.flag_path, flag_checked_at=now, updated_at=now
        )
    return changed


def flag_ready(data: bytes) -> bytes | None:
    """``data`` as the menu serves a flag — a PNG at most ``FLAG_MAX_DIMENSION``
    on its longer side — or ``None`` when it is not a picture."""
    try:
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            picture = ImageOps.exif_transpose(image).convert("RGBA")
    except (
        UnidentifiedImageError,
        DecompressionBombError,
        OSError,
        ValueError,
        MemoryError,
    ):
        return None
    picture.thumbnail((FLAG_MAX_DIMENSION, FLAG_MAX_DIMENSION), Image.Resampling.LANCZOS)
    buffer = io.BytesIO()
    picture.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()
