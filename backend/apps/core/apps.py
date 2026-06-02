from django.apps import AppConfig


class CoreConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.core"

    def ready(self):
        from . import signals  # noqa: F401
        from .discovery import start_discovery_responder

        start_discovery_responder()
