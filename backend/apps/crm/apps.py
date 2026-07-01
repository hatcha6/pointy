from django.apps import AppConfig


class CrmConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.crm"
    verbose_name = "CRM"

    def ready(self):
        from django.db.models.signals import post_save

        from apps.discounts.models import DiscountRule

        from .discount_hooks import on_discount_rule_saved

        post_save.connect(
            on_discount_rule_saved,
            sender=DiscountRule,
            dispatch_uid="crm_auto_campaign_on_discount",
        )
