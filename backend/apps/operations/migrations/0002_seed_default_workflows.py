from django.db import migrations

DEFAULT_WORKFLOWS = [
    {
        "name": "تصليح الأجهزة",
        "job_type": "repair",
        "stages": [
            # (code, name, initial, terminal, approval, consumes, produces)
            ("received", "تم الاستلام", True, False, False, False, False),
            ("diagnosing", "قيد التشخيص", False, False, False, False, False),
            ("waiting_approval", "بانتظار موافقة الزبون", False, False, True, False, False),
            ("repairing", "قيد التصليح", False, False, False, False, False),
            ("testing", "قيد الاختبار", False, False, False, False, False),
            ("ready", "جاهز للتسليم", False, False, False, False, False),
            ("delivered", "تم التسليم", False, True, False, False, False),
        ],
    },
    {
        "name": "دفعة إنتاج",
        "job_type": "production",
        "stages": [
            ("planned", "مخطط", True, False, False, False, False),
            ("in_production", "قيد الإنتاج", False, False, False, True, False),
            ("quality_check", "فحص الجودة", False, False, False, False, False),
            ("finished", "اكتمل الإنتاج", False, True, False, False, True),
        ],
    },
    {
        "name": "طلب مطبخ",
        "job_type": "kitchen",
        "stages": [
            ("received", "تم الاستلام", True, False, False, False, False),
            ("preparing", "قيد التحضير", False, False, False, True, False),
            ("ready", "جاهز", False, False, False, False, False),
            ("served", "تم التقديم", False, True, False, False, False),
        ],
    },
]


def seed_workflows(apps, schema_editor):
    WorkflowTemplate = apps.get_model("operations", "WorkflowTemplate")
    WorkflowStage = apps.get_model("operations", "WorkflowStage")
    for workflow in DEFAULT_WORKFLOWS:
        template, created = WorkflowTemplate.objects.get_or_create(
            job_type=workflow["job_type"],
            is_system=True,
            defaults={"name": workflow["name"], "is_active": True},
        )
        if not created:
            continue
        for order, stage in enumerate(workflow["stages"]):
            code, name, initial, terminal, approval, consumes, produces = stage
            WorkflowStage.objects.create(
                template=template,
                code=code,
                name=name,
                display_order=order,
                is_initial=initial,
                is_terminal=terminal,
                requires_customer_approval=approval,
                consumes_materials=consumes,
                produces_output=produces,
            )


def remove_workflows(apps, schema_editor):
    WorkflowTemplate = apps.get_model("operations", "WorkflowTemplate")
    WorkflowTemplate.objects.filter(is_system=True, jobs__isnull=True).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("operations", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(seed_workflows, remove_workflows),
    ]
