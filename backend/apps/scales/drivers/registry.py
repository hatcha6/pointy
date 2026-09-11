"""Choosing a driver.

Unlike the DVRs, a scale cannot be detected: nothing on this list answers an
identity probe, and the one that would always "succeed" is the file export.
So the shop chooses, and the choice is made easy by the fact that the honest
default — a file every scale can import — is always available and never fails
for a reason the shop cannot see.
"""

from __future__ import annotations

from .aclas_ftp import AclasFtpDriver
from .base import (
    MAX_PLUS_PER_PUSH,
    PluRecord,
    PushOutcome,
    ScaleDriver,
    ScaleError,
    ScaleRefusedError,
    ScaleUnreachableError,
)
from .cas_cl5000 import CasCl5000Driver
from .file_export import FileExportDriver

DRIVER_CLASSES: tuple[type[ScaleDriver], ...] = (
    FileExportDriver,
    CasCl5000Driver,
    AclasFtpDriver,
)

DRIVERS_BY_KEY = {cls.key: cls for cls in DRIVER_CLASSES}

DEFAULT_DRIVER_KEY = FileExportDriver.key

DRIVER_CHOICES = [(cls.key, cls.label) for cls in DRIVER_CLASSES]


def driver_class_for(key: str) -> type[ScaleDriver] | None:
    return DRIVERS_BY_KEY.get(str(key or "").strip().lower())


def build_driver(scale) -> ScaleDriver:
    """The driver a :class:`~apps.scales.models.Scale` row describes."""

    cls = driver_class_for(scale.driver)
    if cls is None:
        raise ScaleError(f"Unknown scale driver '{scale.driver}'.")
    return cls(host=scale.host, port=scale.port, options=dict(scale.options or {}))


__all__ = [
    "DEFAULT_DRIVER_KEY",
    "DRIVER_CHOICES",
    "DRIVER_CLASSES",
    "DRIVERS_BY_KEY",
    "MAX_PLUS_PER_PUSH",
    "PluRecord",
    "PushOutcome",
    "ScaleDriver",
    "ScaleError",
    "ScaleRefusedError",
    "ScaleUnreachableError",
    "build_driver",
    "driver_class_for",
]
