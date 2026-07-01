from django.apps import AppConfig


class MessagingConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.messaging"
    verbose_name = "Messaging"

    def ready(self):
        # Import the transport drivers so their @register side-effects run and the
        # provider registry is populated before the first send.
        from . import transports  # noqa: F401
