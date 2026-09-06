from django.apps import AppConfig


class DocumentsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.documents"
    verbose_name = "Documents"

    def ready(self):
        # Registrations live with the domains that own them; importing them
        # here is what makes the registry complete before the first request.
        from apps.documents import reconciliation, registrations  # noqa: F401
