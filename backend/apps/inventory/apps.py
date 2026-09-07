from django.apps import AppConfig


class InventoryConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.inventory"

    def ready(self):
        # Registers the ``post_migrate`` receiver that adopts stock rows an
        # older backend wrote during a live update, before its warehouse column
        # existed. See ``apps.inventory.reconciliation``.
        from apps.inventory import reconciliation, signals  # noqa: F401
