"""LNET moved its billing to Splynx (``ltel.splynx.app``) in November 2026.

* An account that still names the old portal's address explicitly is pointed
  back at the catalog default, which is now the Splynx host. A blank one
  already follows the default.
* The payments mirror's coverage is forgotten. It described the old portal's
  report; the Cashdesk history is a different log, so "every payment between
  these instants is mirrored" stops being true the moment the driver changes.
  The mirrored rows themselves stay: they are real past top-ups, and a line's
  history keeps showing them.
"""

from django.db import migrations

OLD_HOSTS = ("billing.lnet.ly",)


def forwards(apps, schema_editor):
    IntegrationAccount = apps.get_model("integrations", "IntegrationAccount")
    for account in IntegrationAccount.objects.filter(provider="lnet"):
        fields = []
        if any(host in (account.base_url or "") for host in OLD_HOSTS):
            account.base_url = ""
            fields.append("base_url")
        if account.payments_covered_since or account.payments_synced_at:
            account.payments_covered_since = None
            account.payments_synced_at = None
            fields += ["payments_covered_since", "payments_synced_at"]
        if fields:
            account.save(update_fields=fields)


class Migration(migrations.Migration):
    dependencies = [("integrations", "0022_saved_accounts_and_account_name")]

    operations = [migrations.RunPython(forwards, migrations.RunPython.noop)]
