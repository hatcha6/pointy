from django.apps import AppConfig


class IntegrationsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.integrations"
    verbose_name = "Integrations"

    def ready(self):  # pragma: no cover - import side effect only
        # Registers every provider driver with the registry in providers.base.
        from . import providers  # noqa: F401
        from . import signals  # noqa: F401
