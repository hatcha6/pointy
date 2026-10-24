from django.apps import AppConfig


class PurchasingConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.purchasing"

    def ready(self):
        # One-off: completes Annaseem's order P20261024000010, refused on save
        # 2026-10-24. Delete once that shop has run a release carrying it.
        from apps.purchasing import annaseem_po_repair  # noqa: F401
