from django.apps import AppConfig


class BalancesConfig(AppConfig):
    """Opening balances and balance adjustments on customers' and suppliers'
    accounts — the debts no invoice or purchase order could carry."""

    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.balances"
    verbose_name = "Party balances"
