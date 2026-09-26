"""Which kinds of work a shop runs, and the built-in workflows that follow them.

The shop's settings carry one switch per kind of work — repairs, production,
kitchen — and the first-run wizard sets them from the shop type. The built-in
workflow for each kind is what the jobs board actually shows, so the two have
to agree: a phone shop whose kitchen switch is off must not find a kitchen
board, or a "production batch" option under "new job".

Keeping them in step here, on the server, rather than in whichever screen
flipped the switch, means the wizard, the settings page and any older client
all end in the same place.
"""

from .models import WorkflowTemplate

#: The shop-settings switch that turns each kind of work on. Work orders have
#: none: a work-order workflow is one a shop built for itself on purpose.
MODE_FIELDS = {
    WorkflowTemplate.JobType.REPAIR: "enable_repair_operations",
    WorkflowTemplate.JobType.PRODUCTION: "enable_production_operations",
    WorkflowTemplate.JobType.KITCHEN: "enable_kitchen_operations",
}


def sync_builtin_workflows(settings, *, fields=None):
    """Turn each built-in workflow on or off with the shop's switch for it.

    ``fields`` limits the sync to switches that just changed, so saving an
    unrelated setting never touches a workflow a manager arranged by hand.
    """
    for job_type, field in MODE_FIELDS.items():
        if fields is not None and field not in fields:
            continue
        enabled = bool(getattr(settings, field))
        WorkflowTemplate.objects.filter(job_type=job_type, is_system=True).exclude(
            is_active=enabled
        ).update(is_active=enabled)
