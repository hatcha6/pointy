from django.apps import AppConfig


class PaymentsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.payments"

    def ready(self):
        # Registers the post_migrate catch-up for counter payments an older
        # backend wrote during a live update.
        from apps.payments import reconciliation  # noqa: F401
        # Live Moamalat verification of a card payment just taken.
        from apps.payments.moamalat import signals  # noqa: F401
