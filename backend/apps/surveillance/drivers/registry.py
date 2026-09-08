"""Choosing a driver, including when the installer does not know the brand.

Shop owners rarely know what their DVR is; the sticker says the installer's
name. So ``auto`` is a first-class brand value and detection is a real code
path, not a convenience — it tries each dialect's identity endpoint and takes
the first that answers as itself.

Order matters for speed and, once ONVIF is in the list, for correctness.
Hikvision's ISAPI is the more common of the two named brands in this market and
a Dahua answers its ``/ISAPI/`` probe with a 404 in milliseconds, so leading
with Hikvision costs a Dahua nothing. Xiongmai comes next: it is only probed
on its own port 34567, so a box that is not one refuses the connection in
milliseconds. ONVIF goes last because it is the generic answer — a Hikvision and
a Xiongmai both also speak it, and detecting either as "ONVIF" would trade their
recording search away for nothing.

``generic_rtsp`` is deliberately **not** in the detection order. It has no
identity endpoint — it cannot be detected, only chosen — and putting a driver
that always succeeds into an ordered search would make every box a generic one.
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
from .generic_rtsp import GenericRtspDriver
from .hikvision import HikvisionDriver
from .onvif import OnvifDriver
from .xiongmai import XiongmaiDriver

logger = logging.getLogger(__name__)

BRAND_AUTO = "auto"

#: Tried in order by :func:`detect_driver`. See the module docstring for why
#: ONVIF is last and why ``generic_rtsp`` is absent.
DRIVER_CLASSES: tuple[type[RecorderDriver], ...] = (
    HikvisionDriver,
    DahuaDriver,
    XiongmaiDriver,
    OnvifDriver,
)

#: Everything that can be *chosen*, which is a superset of what can be detected.
DRIVERS_BY_BRAND = {
    cls.brand: cls for cls in (*DRIVER_CLASSES, GenericRtspDriver)
}


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
