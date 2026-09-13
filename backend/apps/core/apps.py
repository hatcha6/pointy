from django.apps import AppConfig


class CoreConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.core"

    def ready(self):
        from . import signals  # noqa: F401
        from .discovery import start_discovery_responder
        from .state_version import connect_signals

        # Declarative: every model named in the state-version registry gets its
        # post_save/post_delete receiver here, so adding a domain never means
        # remembering to wire an app up.
        connect_signals()
        start_discovery_responder()
