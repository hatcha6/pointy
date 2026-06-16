from django.apps import AppConfig


class PriceCheckerConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.price_checker"
    verbose_name = "Price checkers"

    def ready(self):
        # Optional in-process socket daemon for TCP/UDP price checkers. Off by
        # default so it never binds ports in every web worker; production runs
        # it once via `manage.py price_checker_serve`. See daemon.py for guards.
        from .daemon import autostart_price_checker_daemon

        autostart_price_checker_daemon()
