from django.apps import AppConfig


class SalesConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.sales"

    def ready(self):
        # Connects the post_migrate hook that rescues credit due dates written
        # by an older backend during a live update.
        from apps.sales import reconciliation  # noqa: F401
