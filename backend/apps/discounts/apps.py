from django.apps import AppConfig


class DiscountsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.discounts"

    def ready(self):
        # Register discount-preview cache invalidation. The post_save/delete
        # receivers bind on import; the M2M receivers need the through models,
        # so they are connected explicitly here.
        from . import signals

        signals.connect_m2m_signals()

