"""The provider's brand logos: on the card products the till shows, and on receipts.

A cashier who sells cards all day knows them by their logos, the ones the
provider's own app shows. So each card product carries its brand's logo as its
picture, stored like any product picture (an ``Attachment``), and the tiles,
the cart and the product screens show it with nothing new to learn.

The provider also draws every logo for receipts, black on white for a thermal
head (Qareeb's ``logo_print``). That one is kept on the brand, ready to print
(:func:`print_ready`), and every receipt payload carries it inline
(:func:`receipt_logo_for`), so the slip of every card sold opens on its brand's
logo and a printout never waits on a download.

**Fetched once, then left alone.** Logos almost never change, so a brand's logo
is asked for again only a month after it was last read (``LOGO_MAX_AGE``), or as
soon as the provider names a different file for it. A logo that comes back
unchanged costs a download and nothing else: no catalog row moves, so no till
re-reads its catalog.

**Some logos are not there.** A path the provider lists can answer 404 (see
``QareebProvider.voucher_logo``). That never takes away a logo already kept, and
a brand still without one is asked again an hour later (``LOGO_RETRY_AFTER``),
not every sweep.

**A changed tile logo is a new picture.** It is stored as a new attachment and
the old one retired, never rewritten in place: a till caches a picture by its
attachment's URL, which a rewrite keeps, so it would go on showing the old logo.
"""

from __future__ import annotations

import base64
import hashlib
import io
import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import timedelta

from django.db import transaction
from django.db.models import F, Q
from django.utils import timezone
from PIL import Image, ImageOps, UnidentifiedImageError
from PIL.Image import DecompressionBombError

from apps.attachments.image_normalization import normalize_image_bytes
from apps.attachments.image_search import RemoteImageUpload, remote_image_filename
from apps.attachments.models import Attachment
from apps.attachments.services import active_attachments_for, store_uploaded_attachment

from .models import IntegrationVoucherBrand
from .providers import provider_for
from .providers.base import ERROR_UNEXPECTED, VoucherLogo, in_parallel

logger = logging.getLogger(__name__)

#: A logo that is in is asked for again this long after it was last read.
LOGO_MAX_AGE = timedelta(days=30)
#: A logo that is not in (never fetched, a 404, a timeout) is asked for again
#: this long after the last try.
LOGO_RETRY_AFTER = timedelta(hours=1)
#: Logos one sweep may fetch, of both kinds. A new shelf has two hundred or
#: more; this spreads them over the next sweeps rather than holding one sweep
#: for minutes.
LOGO_FETCHES_PER_SWEEP = 24
#: How many downloads run at once.
LOGO_FETCH_CONCURRENCY = 4
#: Tiles show a logo at a few hundred pixels at most, and most arrive at 148.
#: Only the odd 1024 px one is scaled down (it was 1.2 MB).
LOGO_MAX_DIMENSION = 512
#: A receipt prints a logo about 15 mm across: 120 dots on a thermal head,
#: under 200 px on an office printer. Kept a little larger than either, and
#: small enough (a few KB) to ride inline in every receipt payload.
PRINT_LOGO_MAX_DIMENSION = 320
#: Anything this light is paper. Some receipt logos carry a faint background
#: baked into the file (Steam's is a grey checkerboard, Vodafone's a haze, a
#: JPEG's margin is noise): an office printer draws it as a grey box around
#: the logo and a thermal head drops it anyway. Also where the blank margin
#: ends when the logo is trimmed to its ink.
PRINT_PAPER_LEVEL = 212
#: How a stored picture says it is a provider's logo, as an internet search
#: import says ``internet_search``. A changed logo retires only its own kind.
IMPORTED_FROM = "provider_logo"


def sync_logos(account, *, limit: int = LOGO_FETCHES_PER_SWEEP) -> int:
    """Fetch the logos that are due. Returns how many logos changed.

    Tiles first: they are what a cashier looks at all day. The downloads run
    on worker threads and only talk HTTP; every write happens on this thread, a
    batch at a time, so no more than one batch of pictures is held in memory.
    """
    changed = 0
    for kind in (TILE, RECEIPT):
        if limit <= 0:
            break
        due = list(_due(account, kind)[:limit])
        limit -= len(due)
        for start in range(0, len(due), LOGO_FETCH_CONCURRENCY):
            batch = due[start:start + LOGO_FETCH_CONCURRENCY]
            logos = in_parallel(
                [
                    lambda path=getattr(brand, kind.path): _fetch(account, path)
                    for brand in batch
                ]
            )
            for brand, logo in zip(batch, logos):
                changed += _apply(account, kind, brand, logo)
    return changed


def receipt_logo_for(fulfillment, *, memo: dict | None = None) -> str | None:
    """The receipt logo of the brand a card line sold, as base64, or ``None``.

    Only a card has a brand; a top-up of somebody's line has none. ``memo`` is
    shared by one payload's lines, so ten cards of three brands read three rows.
    """
    from .fulfillment import fulfillment_kind

    if fulfillment is None or fulfillment_kind(fulfillment) != "voucher":
        return None
    key = (fulfillment.account_id, (fulfillment.package_id or "").strip())
    if not key[1]:
        return None
    if memo is not None and key in memo:
        return memo[key]
    picture = (
        IntegrationVoucherBrand.objects.filter(account_id=key[0], code=key[1])
        .values_list("print_logo", flat=True)
        .first()
    )
    encoded = base64.b64encode(bytes(picture)).decode("ascii") if picture else None
    if memo is not None:
        memo[key] = encoded
    return encoded


def print_ready(data: bytes) -> bytes | None:
    """``data`` as every receipt prints it, or ``None`` when it is not a picture.

    Grey on white: a transparent logo is laid on the paper it will be printed
    on, not on black. Trimmed to its ink, so every brand's logo fills the same
    box on the slip whatever margin its file came with, and at most
    ``PRINT_LOGO_MAX_DIMENSION`` on its longer side, as a PNG.
    """
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
    paper = Image.new("RGBA", picture.size, "white")
    paper.alpha_composite(picture)
    grey = paper.convert("L").point(
        lambda level: 255 if level >= PRINT_PAPER_LEVEL else level
    )
    ink = grey.point(lambda level: 255 if level < 255 else 0).getbbox()
    if ink is None:
        # A blank picture: nothing worth the space on a slip.
        return None
    grey = grey.crop(ink)
    grey.thumbnail(
        (PRINT_LOGO_MAX_DIMENSION, PRINT_LOGO_MAX_DIMENSION), Image.Resampling.LANCZOS
    )
    # Sixteen greys, white and black exact: nothing a receipt can show is
    # lost (a thermal head prints two), and a logo saved from a JPEG sheds
    # its noise. The biggest one Qareeb sends went from 56 KB to 23 KB.
    grey = grey.point(lambda level: round(level / 17) * 17)
    buffer = io.BytesIO()
    grey.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


# --- one logo, fetched ------------------------------------------------------------
@dataclass(frozen=True)
class _Kind:
    """One of a brand's two logos, and the brand fields that keep track of it."""

    name: str
    #: The field naming the provider's file.
    path: str
    #: The field naming the file whose picture is kept.
    source: str
    #: When the provider was last asked for ``path``.
    checked_at: str
    #: The download as it will be kept, or ``None`` when it is not a picture.
    prepare: Callable[[bytes], object | None]
    #: Keep a prepared picture for a locked brand row. Returns 1 when what a
    #: till shows or prints changed, and names any brand field it set.
    keep: Callable[..., int]


def _keep_on_product(account, row, picture, logo, fields) -> int:
    return _show(
        row.product,
        picture,
        provider=account.provider,
        path=row.logo_path,
        url=logo.url,
        source_sha256=hashlib.sha256(logo.data).hexdigest(),
    )


def _keep_for_receipts(account, row, picture, logo, fields) -> int:
    if bytes(row.print_logo or b"") == picture:
        return 0
    row.print_logo = picture
    fields.append("print_logo")
    return 1


TILE = _Kind(
    name="logo",
    path="logo_path",
    source="logo_source",
    checked_at="logo_checked_at",
    prepare=lambda data: normalize_image_bytes(data, max_dimension=LOGO_MAX_DIMENSION),
    keep=_keep_on_product,
)
RECEIPT = _Kind(
    name="receipt logo",
    path="print_logo_path",
    source="print_logo_source",
    checked_at="print_logo_checked_at",
    prepare=print_ready,
    keep=_keep_for_receipts,
)


def _due(account, kind: _Kind):
    """Listed brands with a product whose ``kind`` of logo is due, never-asked first."""
    now = timezone.now()
    checked = kind.checked_at
    return (
        IntegrationVoucherBrand.objects.filter(
            account=account, is_listed=True, product__isnull=False
        )
        .exclude(**{kind.path: ""})
        .filter(
            Q(**{f"{checked}__isnull": True})
            | Q(**{f"{checked}__lt": now - LOGO_MAX_AGE})
            | (
                ~Q(**{kind.source: F(kind.path)})
                & Q(**{f"{checked}__lt": now - LOGO_RETRY_AFTER})
            )
        )
        .defer("print_logo")
        .order_by(F(checked).asc(nulls_first=True), "pk")
    )


def _fetch(account, path: str) -> VoucherLogo:
    try:
        return provider_for(account).voucher_logo(path)
    except Exception as exc:  # noqa: BLE001 - a driver bug must not stop the sweep
        logger.warning("voucher logo %s crashed", path, exc_info=True)
        return VoucherLogo(ok=False, error_code=ERROR_UNEXPECTED, error_detail=str(exc))


def _apply(account, kind: _Kind, brand, logo: VoucherLogo) -> int:
    """Write down what one download found. Returns 1 when the logo changed."""
    path = getattr(brand, kind.path)
    # Decoding is the check that it is a picture at all: a 200 carrying an
    # error page is as missing as a 404.
    picture = kind.prepare(logo.data) if logo.ok else None
    if picture is None:
        logger.info(
            "no %s for %s brand %s (%s): %s",
            kind.name,
            account.provider,
            brand.code,
            path,
            logo.error_detail or "not an image",
        )
    changed = 0
    with transaction.atomic():
        # Locked so two syncs meeting the same brand keep its logo once. No
        # join to the product here: FOR UPDATE refuses the nullable side of one.
        row = (
            IntegrationVoucherBrand.objects.select_for_update()
            .filter(pk=brand.pk, **{kind.path: path})
            .first()
        )
        if row is None or row.product_id is None:
            # The provider named another file while this one downloaded; that
            # one is due on the next sweep.
            return 0
        fields = [kind.source, kind.checked_at, "updated_at"]
        if picture is not None:
            try:
                with transaction.atomic():
                    changed = kind.keep(account, row, picture, logo, fields)
                setattr(row, kind.source, path)
            except Exception:  # noqa: BLE001 - storage trouble costs a logo, not the sync
                logger.warning(
                    "could not keep the %s for %s", kind.name, brand.code, exc_info=True
                )
        setattr(row, kind.checked_at, timezone.now())
        row.save(update_fields=fields)
    return changed


def _show(product, image, *, provider, path, url, source_sha256) -> int:
    """Make ``image`` the product's picture, unless it already is."""
    ours = [
        attachment
        for attachment in active_attachments_for(product, role=Attachment.Role.PRODUCT_IMAGE)
        if (attachment.metadata or {}).get("imported_from") == IMPORTED_FROM
    ]
    if any((attachment.metadata or {}).get("source_sha256") == source_sha256 for attachment in ours):
        return 0
    store_uploaded_attachment(
        uploaded_file=RemoteImageUpload(
            name=remote_image_filename(url or path, image.extension),
            content_type=image.content_type,
            data=image.data,
        ),
        owner=product,
        role=Attachment.Role.PRODUCT_IMAGE,
        is_primary=True,
        metadata={
            "imported_from": IMPORTED_FROM,
            "provider": provider,
            "logo_path": path,
            "imported_url": url,
            # Of the bytes as the provider served them, so a month-old logo is
            # recognised as unchanged however they were re-encoded to store.
            "source_sha256": source_sha256,
        },
    )
    for attachment in ours:
        attachment.soft_delete()
    return 1
