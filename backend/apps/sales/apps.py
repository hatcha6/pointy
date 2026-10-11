from django.apps import AppConfig


class SalesConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.sales"

    def ready(self):
        # Connects the post_migrate hook that rescues credit due dates written
        # by an older backend during a live update.
        from apps.sales import reconciliation  # noqa: F401
        # One-off: puts Annaseem's drawers right after 2026-10-11. Delete once
        # that shop has run a release carrying it.
        from apps.sales import annaseem_repair  # noqa: F401
