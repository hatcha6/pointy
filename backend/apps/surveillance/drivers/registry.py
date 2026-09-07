"""Choosing a driver, including when the installer does not know the brand.

Shop owners rarely know what their DVR is; the sticker says the installer's
name. So ``auto`` is a first-class brand value and detection is a real code
path, not a convenience — it tries each dialect's identity endpoint and takes
the first that answers as itself.

Order matters only for speed: Hikvision's ISAPI is by far the more common of the
two in this market, and a Dahua answers its ``/ISAPI/`` probe with a 404 in
milliseconds, so leading with Hikvision costs a Dahua nothing.
"""

from __future__ import annotations

import logging

from .base import (
    DeviceInfo,
    RecorderAuthError,
    RecorderDriver,
    RecorderError,
    RecorderTarget,
)
from .dahua import DahuaDriver
from .hikvision import HikvisionDriver

logger = logging.getLogger(__name__)

BRAND_AUTO = "auto"

DRIVER_CLASSES: tuple[type[RecorderDriver], ...] = (HikvisionDriver, DahuaDriver)
DRIVERS_BY_BRAND = {cls.brand: cls for cls in DRIVER_CLASSES}


def driver_class_for_brand(brand: str):
    return DRIVERS_BY_BRAND.get(str(brand or "").strip().lower())


def build_driver(target: RecorderTarget, brand: str) -> RecorderDriver:
    """A driver for a known brand. Never detects — callers that may need
    detection go through :func:`detect_driver`, which is the slow path."""
    driver_class = driver_class_for_brand(brand)
    if driver_class is None:
        raise RecorderError(f"Unsupported recorder brand: {brand!r}")
    return driver_class(target)


def detect_driver(target: RecorderTarget) -> tuple[RecorderDriver, DeviceInfo]:
    """Identify the box, returning a live driver and what it said about itself.

    A rejected password is re-raised immediately rather than being tried against
    the next brand: the credentials are wrong for *this host*, and reporting
    "unsupported recorder" for what is really a typo'd password would send the
    installer looking in the wrong place.
    """
    last_error: RecorderError | None = None
    for driver_class in DRIVER_CLASSES:
        driver = driver_class(target)
        try:
            info = driver.probe()
        except RecorderAuthError:
            driver.close()
            raise
        except RecorderError as exc:
            logger.debug("recorder probe failed as %s: %s", driver_class.brand, exc)
            driver.close()
            last_error = exc
            continue
        return driver, info
    raise last_error or RecorderError(
        "No Hikvision or Dahua recorder answered at that address."
    )
