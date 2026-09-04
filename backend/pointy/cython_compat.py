"""Compatibility shims for running Pointy as compiled extension modules.

Imported from ``pointy/__init__.py`` — the earliest reliable hook, because
``DJANGO_SETTINGS_MODULE=pointy.settings`` imports the ``pointy`` package before
Django loads any app, and these patches must be in place *before* the first
model class is defined.

Safe and behaviour-preserving when nothing is compiled, so it is applied
unconditionally rather than sniffing the build mode: one code path, exercised by
every developer run, instead of a release-only path nobody tests.
"""

from __future__ import annotations

import inspect
from functools import wraps

# Compiled methods are `cython_function_or_method`, not `types.FunctionType`.
# Matching on the type NAME rather than importing a Cython runtime keeps this
# import-free in a plain-Python build.
_CYTHON_FUNCTION = "cython_function_or_method"


def _is_queryset_method(value: object) -> bool:
    """Django's ``inspect.isfunction`` predicate, extended to compiled methods.

    Deliberately NOT ``inspect.isroutine``: that also matches classmethods
    (``QuerySet.as_manager`` among them), which Django's original predicate
    excludes in both modes. Verified against compiled and uncompiled classes —
    plain functions, staticmethods and compiled methods match; classmethods and
    properties do not.
    """
    return inspect.isfunction(value) or type(value).__name__ == _CYTHON_FUNCTION


def _patch_manager_from_queryset() -> None:
    """Restore ``QuerySet.as_manager()`` / ``Manager.from_queryset()``.

    Django builds manager methods with
    ``inspect.getmembers(queryset_class, predicate=inspect.isfunction)``, which
    matches nothing on a compiled queryset class — so every custom queryset
    method silently disappears from the manager and the first call raises
    ``AttributeError: 'ManagerFromXQuerySet' object has no attribute 'active'``.

    Everything below other than the predicate is Django's own implementation.
    """
    from django.db.models.manager import BaseManager

    if getattr(BaseManager, "_pointy_cython_patched", False):
        return

    @classmethod
    def _get_queryset_methods(cls, queryset_class):
        def create_method(name, method):
            @wraps(method)
            def manager_method(self, *args, **kwargs):
                return getattr(self.get_queryset(), name)(*args, **kwargs)

            return manager_method

        new_methods = {}
        for name, method in inspect.getmembers(queryset_class, predicate=_is_queryset_method):
            # Only copy missing methods.
            if hasattr(cls, name):
                continue
            # Only copy public methods or methods with the attribute queryset_only=False.
            queryset_only = getattr(method, "queryset_only", None)
            if queryset_only or (queryset_only is None and name.startswith("_")):
                continue
            new_methods[name] = create_method(name, method)
        return new_methods

    BaseManager._get_queryset_methods = _get_queryset_methods
    BaseManager._pointy_cython_patched = True


def install() -> None:
    """Apply every shim. Never fatal: a partial environment (a management
    command that runs before Django is importable) must not crash on import."""
    try:
        _patch_manager_from_queryset()
    except Exception:  # noqa: BLE001 - import-time; never block startup
        pass
