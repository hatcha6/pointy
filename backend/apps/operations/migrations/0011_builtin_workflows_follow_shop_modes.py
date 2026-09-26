from django.db import migrations

# The shop-settings switch behind each built-in workflow. Mirrors
# ``apps.operations.modes.MODE_FIELDS``, spelled out because a migration must not
# import app code that may change after it is written.
MODE_FIELDS = {
    "repair": "enable_repair_operations",
    "production": "enable_production_operations",
    "kitchen": "enable_kitchen_operations",
}


def retire_unused_workflows_the_shop_switched_off(apps, schema_editor):
    """Stop offering the kinds of work a shop never turned on.

    Every install was seeded with a repair, a production and a kitchen workflow,
    all active, whatever the shop does — so a phone shop's jobs board offered
    production batches and kitchen orders beside its repairs. From now on the
    switches keep the workflows in step; this brings existing shops in line.

    Deliberately narrow, because a board that loses a lane someone was using is
    worse than one that shows a lane too many:

    * only a built-in workflow that has never had a single job is touched —
      anything a shop has used stays exactly as it is;
    * production and kitchen are retired whenever their switch is off;
    * repair only when the shop went through setup and chose a type without
      repairs. Before the wizard existed the repair board was simply there,
      switch or no switch, and a shop still on that footing keeps it.

    Nothing is deleted: turning the switch on in the operations settings brings
    the workflow straight back.
    """
    ShopSettings = apps.get_model("core", "ShopSettings")
    WorkflowTemplate = apps.get_model("operations", "WorkflowTemplate")
    settings = ShopSettings.objects.order_by("pk").first()
    if settings is None:
        # A fresh install: the setup wizard's preset decides, and syncs.
        return
    job_types = ["production", "kitchen"]
    if settings.shop_type:
        job_types.append("repair")
    for job_type in job_types:
        if getattr(settings, MODE_FIELDS[job_type]):
            continue
        unused = list(
            WorkflowTemplate.objects.filter(
                job_type=job_type,
                is_system=True,
                is_active=True,
                jobs__isnull=True,
            ).values_list("pk", flat=True)
        )
        WorkflowTemplate.objects.filter(pk__in=unused).update(is_active=False)


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0037_shopsettings_repair_ticket"),
        ("operations", "0010_job_decline_and_hand_back"),
    ]

    operations = [
        # Nothing to undo into: which workflows were showing before is exactly
        # the state this corrects, and the switches bring any of them back.
        migrations.RunPython(
            retire_unused_workflows_the_shop_switched_off,
            migrations.RunPython.noop,
        ),
    ]
