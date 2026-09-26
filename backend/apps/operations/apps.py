from django.apps import AppConfig


class OperationsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.operations"

    def ready(self):
        # Connects the catch-up for jobs still holding a voided invoice.
        from apps.operations import invoice_returns  # noqa: F401
