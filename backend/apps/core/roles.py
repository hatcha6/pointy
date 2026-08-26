from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import IntegrityError, transaction
from django.db.models import Q

from apps.catalog.variant_option_defaults import DEFAULT_VARIANT_OPTIONS
from apps.expenses.category_defaults import DEFAULT_EXPENSE_CATEGORY_NAMES
from apps.holidays.rules import SOURCE_LOCAL as HOLIDAY_LOCAL_SOURCE

MANAGER_GROUP = "manager"
CASHIER_GROUP = "cashier"
ACCOUNTANT_GROUP = "accountant"
TECHNICIAN_GROUP = "technician"
SUPERVISOR_GROUP = "supervisor"
INVENTORY_CLERK_GROUP = "inventory_clerk"
PURCHASING_AGENT_GROUP = "purchasing_agent"
AUDITOR_GROUP = "auditor"
# Order matters: it is the priority used to resolve a user's single display role
# (manager first). Each user is assigned exactly one role group via
# PosUserSerializer._assign_role, so the priority only ever matters defensively.
ROLE_GROUPS = (
    MANAGER_GROUP,
    SUPERVISOR_GROUP,
    ACCOUNTANT_GROUP,
    AUDITOR_GROUP,
    PURCHASING_AGENT_GROUP,
    INVENTORY_CLERK_GROUP,
    TECHNICIAN_GROUP,
    CASHIER_GROUP,
)
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
    "price_checker",
    "reports",
    "notifications",
    "attachments",
    "employees",
    "attendance",
    "expenses",
    "migration",
    "messaging",
    "crm",
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
    # Required to resolve a scanned barcode at checkout: the POS looks the code up
    # on the product-variants endpoint, which gates on view_productvariant — with
    # only view_product a cashier's scan 403s (browsing/invoicing still work).
    "catalog.view_productvariant",
    "catalog.view_unitofmeasure",
    # Floor staff can run/record stock counts; only managers may apply them
    # (apply_stockcount is granted to managers via MANAGER_PERMISSION_DOMAINS).
    "inventory.view_stockcount",
    "inventory.add_stockcount",
    "inventory.change_stockcount",
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
    # Front-desk staff can read and reply to customer SMS conversations.
    "crm.view_conversations",
    "crm.manage_conversations",
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
    "catalog.view_unitofmeasure",
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
# مشرف / assistant manager: shop-wide oversight plus the ability to run a till.
# reports.view_reportrun is what flips full (shop-wide) visibility on — see
# user_has_full_visibility — and unlocks the revenue dashboards. Deliberately no
# auth.*_user (no user management), no change_shopsettings, no payroll/loans, and
# no fraud management; those stay manager-only.
SUPERVISOR_PERMISSION_CODES = (
    "reports.view_reportrun",
    "analytics.view_analyticsevent",
    "core.view_shopsettings",
    # Sales floor: can operate a register and oversee every session.
    "sales.view_order",
    "sales.add_order",
    "sales.view_registersession",
    "sales.add_registersession",
    "sales.change_registersession",
    "sales.view_registercashmovement",
    "sales.add_registercashmovement",
    "payments.view_payment",
    "payments.add_payment",
    "printing.add_printjob",
    "printing.change_printjob",
    "printing.view_printjob",
    "printing.view_printjobevent",
    "printing.add_printauditevent",
    "printing.change_printauditevent",
    "printing.view_printauditevent",
    # Inventory oversight, including applying counts.
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    "inventory.view_stockitem",
    "inventory.view_stockmovement",
    "inventory.add_stockmovement",
    "inventory.view_stockcount",
    "inventory.add_stockcount",
    "inventory.change_stockcount",
    "inventory.apply_stockcount",
    # Receiving stock against purchase orders.
    "purchasing.view_purchaseorder",
    "purchasing.receive_purchaseorder",
    "purchasing.view_supplier",
    # Customers and floor-level discounting.
    "customers.view_customer",
    "customers.add_customer",
    "customers.change_customer",
    "customers.add_asset",
    "customers.view_asset",
    "discounts.view_discountrule",
    "discounts.add_discountrule",
    "discounts.change_discountrule",
    # Operations oversight: assign, reopen, approve quotes.
    "operations.view_job",
    "operations.add_job",
    "operations.change_job",
    "operations.assign_job",
    "operations.reopen_job",
    "expenses.view_expense",
    "analytics.add_analyticsevent",
)
# أمين المخزن / storekeeper: catalog visibility, the full stock-count loop
# (including apply), stock movements, and receiving against purchase orders.
INVENTORY_CLERK_PERMISSION_CODES = (
    "core.view_shopsettings",
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    "inventory.view_stockitem",
    "inventory.view_stockmovement",
    "inventory.add_stockmovement",
    "inventory.view_stockcount",
    "inventory.add_stockcount",
    "inventory.change_stockcount",
    "inventory.apply_stockcount",
    "purchasing.view_purchaseorder",
    "purchasing.receive_purchaseorder",
    "purchasing.view_supplier",
    "analytics.add_analyticsevent",
)
# مسؤول المشتريات / buyer: the whole purchase-order lifecycle plus suppliers.
PURCHASING_AGENT_PERMISSION_CODES = (
    "core.view_shopsettings",
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    "purchasing.view_supplier",
    "purchasing.add_supplier",
    "purchasing.change_supplier",
    "purchasing.view_purchaseorder",
    "purchasing.add_purchaseorder",
    "purchasing.edit_draft_purchaseorder",
    "purchasing.receive_purchaseorder",
    "purchasing.adjust_received_purchaseorder",
    "purchasing.cancel_purchaseorder",
    "purchasing.add_pos_cash_purchase",
    "purchasing.view_supplierpayment",
    "inventory.view_stockitem",
    "inventory.view_stockmovement",
    "analytics.add_analyticsevent",
)
# مدقق / auditor: read-only across the operational and financial picture. No
# add/change/delete anywhere. HR/payroll is deliberately excluded — grant it
# per-user when an owner wants an HR auditor (that is what extra permissions are
# for). reports.view_reportrun gives shop-wide read visibility + dashboards.
AUDITOR_PERMISSION_CODES = (
    "reports.view_reportrun",
    "analytics.view_analyticsevent",
    "core.view_shopsettings",
    "sales.view_order",
    "sales.view_registersession",
    "sales.view_registercashmovement",
    "payments.view_payment",
    "inventory.view_stockitem",
    "inventory.view_stockmovement",
    "inventory.view_stockcount",
    "purchasing.view_purchaseorder",
    "purchasing.view_supplier",
    "purchasing.view_supplierpayment",
    "customers.view_customer",
    "customers.view_asset",
    "discounts.view_discountrule",
    "expenses.view_expense",
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    "operations.view_job",
)
# Single source of truth mapping a role group to the codenames it bundles. Used
# to surface "permissions inherited from the role" without hitting the database
# per row. Manager is intentionally absent: it holds every permission and is
# represented by the "*" sentinel in role_permission_codes().
ROLE_PERMISSION_CODES = {
    CASHIER_GROUP: CASHIER_PERMISSION_CODES,
    ACCOUNTANT_GROUP: ACCOUNTANT_PERMISSION_CODES,
    TECHNICIAN_GROUP: TECHNICIAN_PERMISSION_CODES,
    SUPERVISOR_GROUP: SUPERVISOR_PERMISSION_CODES,
    INVENTORY_CLERK_GROUP: INVENTORY_CLERK_PERMISSION_CODES,
    PURCHASING_AGENT_GROUP: PURCHASING_AGENT_PERMISSION_CODES,
    AUDITOR_GROUP: AUDITOR_PERMISSION_CODES,
}


def role_permission_codes(role):
    """Return the frozenset of ``app_label.codename`` strings a role grants.

    Returns ``None`` for the manager role, which holds every permission.
    """
    if role == MANAGER_GROUP:
        return None
    return frozenset(ROLE_PERMISSION_CODES.get(role, ()))


def assigned_role_from_group_names(group_names, *, is_superuser=False):
    """Resolve a user's single display role from the names of groups they belong
    to, honouring ROLE_GROUPS priority (manager/superuser first)."""
    if is_superuser or MANAGER_GROUP in group_names:
        return MANAGER_GROUP
    for role in ROLE_GROUPS:
        if role in group_names:
            return role
    return None


def _permission_map(permission_codes):
    """Resolve ``app_label.codename`` strings to ``Permission`` rows in ONE query.

    Keyed by the exact ``app_label.codename`` string, so the two flat ``__in``
    lists are safe: they can over-fetch a cross product (an app_label from one
    code paired with a codename from another), but those rows are simply never
    looked up. Two ``__in`` lists are deliberate over an OR of per-code tuples —
    same result, and one index scan instead of 200-odd OR branches for the
    planner to chew through.
    """
    pairs = [permission_code.split(".", 1) for permission_code in permission_codes]
    if not pairs:
        return {}
    permissions = Permission.objects.filter(
        content_type__app_label__in={app_label for app_label, _ in pairs},
        codename__in={codename for _, codename in pairs},
    ).select_related("content_type")
    return {
        f"{permission.content_type.app_label}.{permission.codename}": permission
        for permission in permissions
    }


def _permissions_for_codes(permission_codes, permission_map=None):
    """The ``Permission`` rows for ``permission_codes``, in that order, silently
    skipping codes with no matching row (an app whose migrations have not run).

    Pass ``permission_map`` to reuse a map already built for a wider set of
    codes; without it one is built for just these codes.
    """
    if permission_map is None:
        permission_map = _permission_map(permission_codes)
    return [
        permission_map[permission_code]
        for permission_code in permission_codes
        if permission_code in permission_map
    ]


def ensure_role_groups():
    groups = {
        role: Group.objects.get_or_create(name=role)[0]
        for role in ROLE_GROUPS
    }

    manager_permissions = Permission.objects.filter(
        content_type__app_label__in=MANAGER_PERMISSION_DOMAINS,
    )
    # Resolve every code the eight roles need in a single query, then slice it
    # per role. This used to be one ``.filter(...).first()`` per code — 211 of
    # them — and ensure_role_groups runs on *every* request to the users screen
    # (``PosUserViewSet.initial``), so that was 211 round trips on a read path.
    # Keep the resolution batched here; do not push it back inside the loop.
    permission_map = _permission_map(
        [
            *USER_PERMISSION_CODES,
            *(code for codes in ROLE_PERMISSION_CODES.values() for code in codes),
        ]
    )
    manager_user_permissions = _permissions_for_codes(
        USER_PERMISSION_CODES, permission_map
    )

    groups[MANAGER_GROUP].permissions.add(*manager_permissions, *manager_user_permissions)
    for role, codes in ROLE_PERMISSION_CODES.items():
        groups[role].permissions.set(_permissions_for_codes(codes, permission_map))
    return groups


def user_has_role(user, role):
    if not user or not user.is_authenticated:
        return False
    if user.is_superuser:
        return True
    return user.groups.filter(name=role).exists()


def user_is_manager(user):
    return user_has_role(user, MANAGER_GROUP)


def user_has_full_visibility(user):
    """Whether a user may see shop-wide records rather than only their own
    register session's. True for managers and any reporting role (anyone holding
    ``reports.view_reportrun`` — managers, accountants, supervisors, auditors).

    This is the read/visibility counterpart to manager-only *authority* (refunds,
    voids, post-window adjustments), which stays gated on ``user_is_manager``.
    """
    if not user or not user.is_authenticated:
        return False
    if user.is_superuser or user_is_manager(user):
        return True
    return user.has_perm("reports.view_reportrun")


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
    if model_label == ("inventory", "warehouse"):
        # The default "Main" warehouse is created by migration so the valuation
        # ledger always has somewhere to post. It is scaffolding, not activity —
        # a shop that has added a second location has actually done something.
        return queryset.filter(is_default=False).exists()
    if model_label == ("catalog", "unitofmeasure"):
        # Seeded built-in units are configuration scaffolding, not shop activity.
        return queryset.filter(is_system=False).exists()
    if model_label == ("holidays", "holiday"):
        # Built-in (migration-seeded) and relay-synced holidays are configuration,
        # not shop activity — only a shop-authored local holiday counts.
        return queryset.filter(source=HOLIDAY_LOCAL_SOURCE).exists()
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
