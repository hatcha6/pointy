from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import IntegrityError, transaction
from django.db.models import Q

from apps.catalog.variant_option_defaults import DEFAULT_VARIANT_OPTIONS
from apps.expenses.category_defaults import DEFAULT_EXPENSE_CATEGORY_NAMES

MANAGER_GROUP = "manager"
CASHIER_GROUP = "cashier"
ACCOUNTANT_GROUP = "accountant"
TECHNICIAN_GROUP = "technician"
ROLE_GROUPS = (MANAGER_GROUP, CASHIER_GROUP, ACCOUNTANT_GROUP, TECHNICIAN_GROUP)
INITIAL_SETUP_IGNORED_MODELS = {
    ("admin", "logentry"),
    ("analytics", "analyticsevent"),
    ("auth", "group"),
    ("auth", "permission"),
    ("auth", "user"),
    ("contenttypes", "contenttype"),
    ("sessions", "session"),
}
INITIAL_SETUP_VARIANT_OPTION_CODES = {
    option["code"]
    for option in DEFAULT_VARIANT_OPTIONS
}
INITIAL_SETUP_VARIANT_VALUE_CODES_BY_OPTION = {
    option["code"]: {code for code, _name, _display_order in option["values"]}
    for option in DEFAULT_VARIANT_OPTIONS
}
INITIAL_SETUP_UNSPECIFIED_SUPPLIER_NAME = "مورد غير محدد"
INITIAL_SETUP_UNSPECIFIED_SUPPLIER_NOTES = (
    "تم إنشاؤه لربط أوامر الشراء القديمة التي لم يكن لها مورد."
)

MANAGER_PERMISSION_DOMAINS = (
    "catalog",
    "analytics",
    "channels",
    "core",
    "operations",
    "inventory",
    "sales",
    "fraud",
    "customers",
    "discounts",
    "purchasing",
    "payments",
    "printing",
    "reports",
    "notifications",
    "attachments",
    "employees",
    "attendance",
    "expenses",
)
USER_PERMISSION_CODES = (
    "auth.add_user",
    "auth.change_user",
    "auth.delete_user",
    "auth.view_user",
)
CASHIER_PERMISSION_CODES = (
    "catalog.view_product",
    "catalog.view_productcategory",
    "sales.add_order",
    "sales.view_order",
    "sales.add_registersession",
    "sales.change_registersession",
    "sales.view_registersession",
    "sales.add_registercashmovement",
    "sales.view_registercashmovement",
    "payments.add_payment",
    "payments.view_payment",
    "core.view_shopsettings",
    "printing.add_printjob",
    "printing.change_printjob",
    "printing.view_printjob",
    "printing.view_printjobevent",
    "printing.add_printauditevent",
    "printing.change_printauditevent",
    "printing.view_printauditevent",
    "analytics.add_analyticsevent",
    "operations.add_job",
    "operations.change_job",
    "operations.view_job",
    "operations.assign_job",
    "operations.add_jobasset",
    "operations.view_jobasset",
    "operations.view_jobmaterial",
    "operations.view_jobstageevent",
    "operations.view_workflowtemplate",
    "operations.view_workflowstage",
    "customers.add_asset",
    "customers.view_asset",
)
TECHNICIAN_PERMISSION_CODES = (
    "operations.add_job",
    "operations.change_job",
    "operations.view_job",
    "operations.add_jobasset",
    "operations.view_jobasset",
    "operations.add_jobmaterial",
    "operations.change_jobmaterial",
    "operations.view_jobmaterial",
    "operations.view_jobstageevent",
    "operations.view_workflowtemplate",
    "operations.view_workflowstage",
    "customers.view_customer",
    "customers.add_customer",
    "customers.change_customer",
    "customers.add_asset",
    "customers.change_asset",
    "customers.view_asset",
    "catalog.view_product",
    "catalog.view_productcategory",
    "core.view_shopsettings",
    "attachments.add_attachment",
    "attachments.view_attachment",
    "analytics.add_analyticsevent",
)
ACCOUNTANT_PERMISSION_CODES = (
    "auth.view_user",
    "core.view_shopsettings",
    "analytics.view_analyticsevent",
    "customers.view_customer",
    "discounts.view_discountrule",
    "employees.add_compensationplan",
    "employees.change_compensationplan",
    "employees.view_compensationplan",
    "employees.add_employee",
    "employees.change_employee",
    "employees.view_employee",
    "employees.view_employeeloan",
    "employees.change_employeeloan",
    "employees.approve_employeeloan",
    "employees.reject_employeeloan",
    "employees.add_payrollrun",
    "employees.change_payrollrun",
    "employees.view_payrollrun",
    "employees.approve_payrollrun",
    "employees.mark_payrollrun_paid",
    "employees.void_payrollrun",
    "payments.view_payment",
    "purchasing.view_purchaseorder",
    "purchasing.view_supplier",
    "purchasing.view_supplierpayment",
    "reports.view_reportrun",
    "sales.view_order",
    "sales.view_registersession",
    "sales.view_registercashmovement",
    "expenses.add_expense",
    "expenses.change_expense",
    "expenses.delete_expense",
    "expenses.view_expense",
    "expenses.add_expensecategory",
    "expenses.change_expensecategory",
    "expenses.delete_expensecategory",
    "expenses.view_expensecategory",
    "attendance.view_biotimeconnection",
    "attendance.change_biotimeconnection",
    "attendance.view_attendanceprofile",
    "attendance.change_attendanceprofile",
    "attendance.view_attendancepunch",
    "attendance.view_attendanceday",
)


def _permissions_for_codes(permission_codes):
    permissions = []
    for permission_code in permission_codes:
        app_label, codename = permission_code.split(".", 1)
        permission = Permission.objects.filter(
            content_type__app_label=app_label,
            codename=codename,
        ).first()
        if permission is not None:
            permissions.append(permission)
    return permissions


def ensure_role_groups():
    groups = {
        role: Group.objects.get_or_create(name=role)[0]
        for role in ROLE_GROUPS
    }

    manager_permissions = Permission.objects.filter(
        content_type__app_label__in=MANAGER_PERMISSION_DOMAINS,
    )
    manager_user_permissions = _permissions_for_codes(USER_PERMISSION_CODES)
    cashier_permissions = _permissions_for_codes(CASHIER_PERMISSION_CODES)
    accountant_permissions = _permissions_for_codes(ACCOUNTANT_PERMISSION_CODES)
    technician_permissions = _permissions_for_codes(TECHNICIAN_PERMISSION_CODES)

    groups[MANAGER_GROUP].permissions.add(*manager_permissions, *manager_user_permissions)
    groups[CASHIER_GROUP].permissions.add(*cashier_permissions)
    groups[ACCOUNTANT_GROUP].permissions.add(*accountant_permissions)
    groups[TECHNICIAN_GROUP].permissions.add(*technician_permissions)
    return groups


def user_has_role(user, role):
    if not user or not user.is_authenticated:
        return False
    if user.is_superuser:
        return True
    return user.groups.filter(name=role).exists()


def user_is_manager(user):
    return user_has_role(user, MANAGER_GROUP)


def initial_admin_setup_required():
    User = get_user_model()
    return not User.objects.exists() and not pointy_domain_data_exists()


def pointy_domain_data_exists():
    for model in apps.get_models():
        model_label = (model._meta.app_label, model._meta.model_name)
        if model_label in INITIAL_SETUP_IGNORED_MODELS:
            continue
        try:
            if _model_has_initial_setup_blocking_data(model, model_label):
                return True
        except Exception:
            return True
    return False


def _model_has_initial_setup_blocking_data(model, model_label):
    queryset = model._default_manager.all()
    if model_label == ("channels", "saleschannel"):
        # The built-in POS channel is seeded data, not shop activity.
        return queryset.filter(is_system=False).exists()
    if model_label == ("attendance", "biotimeconnection"):
        # An untouched singleton row is configuration scaffolding, not activity.
        return queryset.exclude(base_url="").exists()
    if model_label == ("operations", "workflowtemplate"):
        # Seeded default workflows are configuration, not shop activity.
        return queryset.filter(is_system=False).exists()
    if model_label == ("expenses", "expensecategory"):
        # Seeded default expense categories are configuration, not activity.
        return queryset.exclude(name__in=DEFAULT_EXPENSE_CATEGORY_NAMES).exists()
    if model_label == ("operations", "workflowstage"):
        return queryset.filter(template__is_system=False).exists()
    if model_label == ("catalog", "variantoption"):
        return queryset.exclude(
            code__in=INITIAL_SETUP_VARIANT_OPTION_CODES,
        ).exists()
    if model_label == ("catalog", "variantoptionvalue"):
        return queryset.exclude(_initial_setup_seed_variant_value_query()).exists()
    if model_label == ("purchasing", "supplier"):
        return queryset.exclude(
            name=INITIAL_SETUP_UNSPECIFIED_SUPPLIER_NAME,
            contact_name="",
            phone="",
            email="",
            address="",
            notes=INITIAL_SETUP_UNSPECIFIED_SUPPLIER_NOTES,
            is_active=True,
            purchase_orders__isnull=True,
        ).distinct().exists()
    return queryset.exists()


def _initial_setup_seed_variant_value_query():
    query = Q()
    for option_code, value_codes in INITIAL_SETUP_VARIANT_VALUE_CODES_BY_OPTION.items():
        query |= Q(option__code=option_code, code__in=value_codes)
    return query


def create_initial_admin_user(
    *,
    username=None,
    email="",
    password=None,
    first_name="",
    last_name="",
    enabled=True,
):
    User = get_user_model()
    if not enabled or not password:
        return None

    username = (username or "admin").strip()
    if not username:
        return None

    try:
        with transaction.atomic():
            groups = ensure_role_groups()
            list(
                Group.objects.select_for_update()
                .filter(name__in=ROLE_GROUPS)
                .order_by("name")
            )
            if User.objects.exists() or pointy_domain_data_exists():
                return None
            admin = User.objects.create_superuser(
                username=username,
                email=email or "",
                password=password,
                first_name=first_name or "",
                last_name=last_name or "",
            )
            admin.groups.add(groups[MANAGER_GROUP])
    except IntegrityError:
        return None
    admin._pointy_initial_admin_created = True
    return admin
