"""Connector registry with lightweight autodiscovery.

Every module in this package is imported and any :class:`BaseConnector`
subclass with a ``system_key`` is registered. Adding a new vendor connector is
therefore a one-file change — drop ``connectors/<vendor>.py`` and it appears in
the picker automatically. Discovery never imports a database driver (connectors
only declare metadata + read through a transport at run time).
"""

from __future__ import annotations

import importlib
import pkgutil

from .base import BaseConnector, CompatibilityReport, ExtractContext, RequiredTable, VersionSpec

CONNECTOR_REGISTRY: dict[str, BaseConnector] = {}
_SKIP_MODULES = {"base"}


def _discover() -> None:
    if CONNECTOR_REGISTRY:
        return
    for module_info in pkgutil.iter_modules(__path__):
        if module_info.name in _SKIP_MODULES:
            continue
        module = importlib.import_module(f"{__name__}.{module_info.name}")
        for value in vars(module).values():
            if (
                isinstance(value, type)
                and issubclass(value, BaseConnector)
                and value is not BaseConnector
                and getattr(value, "system_key", "")
            ):
                CONNECTOR_REGISTRY.setdefault(value.system_key, value())


def get_connector(system_key: str) -> BaseConnector | None:
    _discover()
    return CONNECTOR_REGISTRY.get(system_key)


def list_connectors() -> list[BaseConnector]:
    _discover()
    return sorted(CONNECTOR_REGISTRY.values(), key=lambda connector: connector.display_name)


__all__ = [
    "BaseConnector",
    "CompatibilityReport",
    "ExtractContext",
    "RequiredTable",
    "VersionSpec",
    "CONNECTOR_REGISTRY",
    "get_connector",
    "list_connectors",
]
