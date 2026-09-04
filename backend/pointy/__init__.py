# The Cython shims must land before Django defines any model class, so they come
# first — ahead of the Celery app, which pulls in settings. See pointy.cython_compat.
from .cython_compat import install as _install_cython_shims

_install_cython_shims()

from .celery import app as celery_app  # noqa: E402 - must follow the shims

__all__ = ("celery_app",)
