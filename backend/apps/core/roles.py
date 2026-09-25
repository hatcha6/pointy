from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import IntegrityError, transaction

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
#: The rows that prove a shop has actually started working, and the ONLY rows
#: that close the door on the first-run wizard.
#:
#: This list is deliberately an allow-list rather than the "scan every model and
#: exempt the innocent ones" denylist it replaces. That denylist bricked a real
#: install: ``core.run_due_scheduled_backup`` runs every 60 seconds and calls
#: ``SystemBackupSchedule.load()``, which materialises its singleton row. One
#: minute after the containers came up — before anyone had ever opened the app —
#: the scan found that row, concluded the shop was already in business, and
#: answered ``requires_onboarding: false``. The owner got a login screen for an
#: installation with no users in it, and the only way in was
#: ``docker exec ... createsuperuser``.
#:
#: That failure mode is the whole reason for the inversion. Under a denylist,
#: every new model, every migration that seeds a default, and every background
#: task that touches a table before first login is a fresh chance to lock the
#: owner out of their own shop, and it fails *silently* and *permanently*.
#: Under an allow-list the same mistakes are harmless: an unlisted model simply
#: does not vote, so the worst case is that the wizard stays reachable slightly
#: longer than it strictly needed to — recoverable, and visible.
#:
#: What belongs here: a model whose rows can only exist because a person did
#: shop work. What does not: anything a migration seeds, anything boot or a
#: periodic task writes, and anything synced from the relay. Every entry is
#: checked by ``test_shop_activity_models_are_empty_on_a_fresh_install``, which
#: fails if a model on this list ever starts arriving pre-seeded.
INITIAL_SETUP_SHOP_ACTIVITY_MODELS = (
    ("sales", "order"),
    ("sales", "registersession"),
    ("catalog", "product"),
    ("catalog", "productcategory"),
    ("customers", "customer"),
    ("customers", "asset"),
    # A balance typed onto a customer's or a supplier's account is shop work
    # by definition — nothing seeds one — and a supplier's opening balance can
    # be the first thing an owner enters.
    ("balances", "customerbalanceentry"),
    ("balances", "supplierbalanceentry"),
    ("balances", "employeebalanceentry"),
    ("purchasing", "purchaseorder"),
    ("inventory", "stockmovement"),
    ("inventory", "stockledgerentry"),
    ("inventory", "stockcount"),
    ("payments", "payment"),
    ("expenses", "expense"),
    ("operations", "job"),
    ("employees", "employee"),
    ("discounts", "discountrule"),
    ("treasury", "moneycount"),
    ("treasury", "moneytransfer"),
    # Peripherals somebody configured by hand. Deliberately NOT here:
    # ``printing.printagent`` and ``price_checker.pricecheckerdevice``, which
    # self-register over the LAN — a kiosk or print agent left running from an
    # earlier install can announce itself to a brand-new backend before its
    # owner has opened the app, which is the very thing this list must not
    # mistake for shop work.
    ("printing", "printerprofile"),
    ("scales", "scale"),
    ("surveillance", "recorder"),
    ("messaging", "messaginggateway"),
    ("integrations", "integrationaccount"),
    # A finished data import is the clearest possible evidence that this
    # installation already belongs to a shop, even before anyone logs in.
    ("migration", "migrationrun"),
)

MANAGER_PERMISSION_DOMAINS = (
    "catalog",
    "scales",
    "fx",
    "analytics",
    "channels",
    "core",
    "operations",
    "inventory",
    "sales",
    "fraud",
    "customers",
    # Opening balances and adjustments on customers' and suppliers' accounts.
    "balances",
    "discounts",
    "purchasing",
    "payments",
    "printing",
    "price_checker",
    "surveillance",
    "reports",
    "notifications",
    "attachments",
    "employees",
    "attendance",
    "expenses",
    "treasury",
    "migration",
    "messaging",
    "crm",
    "integrations",
)
USER_PERMISSION_CODES = (
    "auth.add_user",
    "auth.change_user",
    "auth.delete_user",
    "auth.view_user",
)
CASHIER_PERMISSION_CODES = (
    # Looking a subscriber up and putting a top-up in the cart is till work.
    # Configuring the provider account is not, and stays on manage_integrations.
    "integrations.use_integrations",
    "catalog.view_product",
    "catalog.view_productcategory",
    # Required to resolve a scanned barcode at checkout: the POS looks the code up
    # on the product-variants endpoint, which gates on view_productvariant — with
    # only view_product a cashier's scan 403s (browsing/invoicing still work).
    "catalog.view_productvariant",
    "catalog.view_unitofmeasure",
    # The till has to know how its scales lay out a label before it can read one.
    "catalog.view_scalebarcoderule",
    # Floor staff can run/record stock counts; only managers may apply them
    # (apply_stockcount is granted to managers via MANAGER_PERMISSION_DOMAINS).
    "inventory.view_stockcount",
    "inventory.add_stockcount",
    "inventory.change_stockcount",
    # A till has to see which handset it is selling and which lot it is picking
    # from. It does not see what either cost — that is a used-goods norm, and
    # easier to grant later than to claw back.
    "inventory.view_stockunit",
    "inventory.view_stockbatch",
    # The counter is where a consignor turns up to collect, so the cashier can
    # see what is owed and hand it over. It is audited, it prints a voucher both
    # parties sign, and a shop that would rather it were a manager's job revokes
    # it per user.
    "inventory.view_consignmentagreement",
    "inventory.view_consignment_liability",
    "inventory.disburse_consignment_payout",
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
    # At a repair counter the cashier is the one who writes the parts onto the
    # job: the screen fitted is sold the same way it would be over the till, and
    # it leaves stock through the same audited movement.
    "operations.add_jobmaterial",
    "operations.view_jobmaterial",
    "operations.view_jobstageevent",
    "operations.view_workflowtemplate",
    "operations.view_workflowstage",
    # NOT customers.add_customer, though repair intake wants it: the frozen
    # compat/win8 till build still opens the customer-balances dashboard for
    # anyone holding it, and those tills run against this backend. It stays a
    # per-user grant until that build is retired.
    "customers.add_asset",
    # Front-desk staff take items in, so they also correct a mistyped IMEI and
    # record a device that changed hands. Withholding this would mean a manager
    # for every typo, which in practice means the typo stays.
    "customers.change_asset",
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
    # The till has to know how its scales lay out a label before it can read one.
    "catalog.view_scalebarcoderule",
    "core.view_shopsettings",
    "attachments.add_attachment",
    "attachments.view_attachment",
    "analytics.add_analyticsevent",
)
ACCOUNTANT_PERMISSION_CODES = (
    # Paying a provider to refill its float is money-out work, done
    # by whoever is standing at the provider's office — not by the
    # owner from the settings screen.
    "integrations.record_integration_topup",
    "auth.view_user",
    "core.view_shopsettings",
    # An accountant reconciling import costs needs to see which rate a price was
    # struck at, and to enter the rate actually paid when it differed from the
    # published one — but not to reconfigure the catalogue around it.
    "fx.view_currency",
    "fx.view_exchangerate",
    "fx.add_exchangerate",
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
    # Closing a period is bookkeeping, not shop configuration: the accountant
    # is the person who decides that September is finished, and they
    # deliberately do not hold ``core.change_shopsettings``.
    "reports.manage_period_lock",
    "sales.view_order",
    "sales.view_registersession",
    "sales.view_registercashmovement",
    # Closing stock is a mandatory input to the accounts, and the role
    # responsible for the accounts could not obtain it: the stock value,
    # movement and reorder reports were all hidden from the accountant because
    # this list carried no inventory permission at all. Read-only — an
    # accountant reports on stock, they do not adjust it.
    "inventory.view_stockitem",
    "inventory.view_warehouse",
    "inventory.view_stocktransfer",
    "sales.view_registerprofile",
    "inventory.view_stockmovement",
    "inventory.view_stockcount",
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    # The till has to know how its scales lay out a label before it can read one.
    "catalog.view_scalebarcoderule",
    "expenses.add_expense",
    "expenses.change_expense",
    "expenses.delete_expense",
    "expenses.view_expense",
    "expenses.add_expensecategory",
    "expenses.change_expensecategory",
    "expenses.delete_expensecategory",
    "expenses.view_expensecategory",
    "treasury.view_moneyaccount",
    "treasury.add_moneyaccount",
    "treasury.change_moneyaccount",
    "treasury.view_moneytransfer",
    "treasury.add_moneytransfer",
    "treasury.view_moneycount",
    "treasury.add_moneycount",
    "attendance.view_biotimeconnection",
    "attendance.change_biotimeconnection",
    "attendance.view_attendanceprofile",
    "attendance.change_attendanceprofile",
    "attendance.view_attendancepunch",
    "attendance.view_attendanceday",
    # Opening balances and adjustments on customers' and suppliers' accounts
    # are bookkeeping: the accountant is the person who carries a paper
    # ledger's balances in and corrects them later. Withdrawing one is refused
    # once anything has been settled against it, whoever asks.
    "balances.view_customerbalanceentry",
    "balances.add_customerbalanceentry",
    "balances.cancel_customerbalanceentry",
    "balances.view_supplierbalanceentry",
    "balances.add_supplierbalanceentry",
    "balances.cancel_supplierbalanceentry",
    # And on employees' accounts, which the accountant already runs payroll
    # against: an opening balance carried in, a correction, cash settled.
    "balances.view_employeebalanceentry",
    "balances.add_employeebalanceentry",
    "balances.cancel_employeebalanceentry",
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
    # The till has to know how its scales lay out a label before it can read one.
    "catalog.view_scalebarcoderule",
    "inventory.view_stockitem",
    "inventory.view_warehouse",
    "inventory.view_stocktransfer",
    "sales.view_registerprofile",
    "inventory.view_stockmovement",
    "inventory.add_stockmovement",
    "inventory.view_stockcount",
    "inventory.add_stockcount",
    "inventory.change_stockcount",
    "inventory.apply_stockcount",
    "inventory.view_stockunit",
    "inventory.add_stockunit",
    "inventory.change_stockunit",
    "inventory.view_stockbatch",
    "inventory.manage_batches",
    "inventory.adjust_batch_balance",
    # Taking somebody's watch in on consignment is stock work: the clerk writes
    # the voucher, a manager settles anything that goes wrong with it.
    "inventory.view_consignmentagreement",
    "inventory.manage_consignmentagreement",
    "inventory.view_consignment_liability",
    # And **writing down** what went wrong is stock work too: whoever noticed
    # the broken camera has to be able to record it at the time, before
    # anybody has decided who is responsible. Paying the claim is
    # ``disburse_consignment_payout``, which this role does not have (§6.2.2).
    "inventory.manage_consignmentincident",
    # Stop-sale on a recalled lot, for the same reason: the person who reads
    # the notice is the person who has to act on it, and waiting for a manager
    # is the window the recall is about.
    "inventory.quarantine_batch",
    # Receiving stock against purchase orders.
    "purchasing.view_purchaseorder",
    "purchasing.receive_purchaseorder",
    "purchasing.view_supplier",
    # Customers and floor-level discounting.
    "customers.view_customer",
    "customers.add_customer",
    "customers.change_customer",
    # Sees the balances written onto a customer's account; writing one is an
    # owner's or an accountant's act, granted per person when wanted.
    "balances.view_customerbalanceentry",
    "customers.add_asset",
    "customers.change_asset",
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
    # Cameras: a floor supervisor watches and reviews, but exporting footage is
    # a manager act — it leaves the building.
    "surveillance.view_camera",
    "surveillance.view_live",
    "surveillance.view_playback",
    "analytics.add_analyticsevent",
)
# أمين المخزن / storekeeper: catalog visibility, the full stock-count loop
# (including apply), stock movements, and receiving against purchase orders.
INVENTORY_CLERK_PERMISSION_CODES = (
    "core.view_shopsettings",
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    # The till has to know how its scales lay out a label before it can read one.
    "catalog.view_scalebarcoderule",
    "inventory.view_stockitem",
    "inventory.view_warehouse",
    "inventory.view_stocktransfer",
    "sales.view_registerprofile",
    "inventory.view_stockmovement",
    "inventory.add_stockmovement",
    "inventory.view_stockcount",
    "inventory.add_stockcount",
    "inventory.change_stockcount",
    "inventory.apply_stockcount",
    "inventory.view_stockunit",
    "inventory.add_stockunit",
    "inventory.change_stockunit",
    "inventory.view_stockbatch",
    "inventory.manage_batches",
    "inventory.adjust_batch_balance",
    # The person who reads the recall notice is the person who has to act on
    # it, and waiting for a manager is the window the recall is about (§6.8.1).
    "inventory.quarantine_batch",
    "purchasing.view_purchaseorder",
    "purchasing.receive_purchaseorder",
    "purchasing.view_supplier",
    "analytics.add_analyticsevent",
)
# مسؤول المشتريات / buyer: the whole purchase-order lifecycle plus suppliers.
PURCHASING_AGENT_PERMISSION_CODES = (
    # Paying a provider to refill its float is money-out work, done
    # by whoever is standing at the provider's office — not by the
    # owner from the settings screen.
    "integrations.record_integration_topup",
    "core.view_shopsettings",
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    # The till has to know how its scales lay out a label before it can read one.
    "catalog.view_scalebarcoderule",
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
    # What the shop owes a supplier beyond any order is part of the conversation
    # a buyer has with them — read-only.
    "balances.view_supplierbalanceentry",
    # A buyer captures identifiers where the goods are — at the receiving bay —
    # so receiving a serialized or lot-tracked delivery is part of the job.
    "inventory.view_stockunit",
    "inventory.add_stockunit",
    "inventory.view_stockbatch",
    "inventory.manage_batches",
    "inventory.view_stockitem",
    "inventory.view_warehouse",
    "inventory.view_stocktransfer",
    "sales.view_registerprofile",
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
    "inventory.view_warehouse",
    "inventory.view_stocktransfer",
    "sales.view_registerprofile",
    "inventory.view_stockmovement",
    "inventory.view_stockcount",
    "purchasing.view_purchaseorder",
    "purchasing.view_supplier",
    "purchasing.view_supplierpayment",
    "customers.view_customer",
    "customers.view_asset",
    "balances.view_customerbalanceentry",
    "balances.view_supplierbalanceentry",
    "discounts.view_discountrule",
    "expenses.view_expense",
    "treasury.view_moneyaccount",
    "treasury.view_moneytransfer",
    "treasury.view_moneycount",
    "catalog.view_product",
    "catalog.view_productcategory",
    "catalog.view_unitofmeasure",
    # The till has to know how its scales lay out a label before it can read one.
    "catalog.view_scalebarcoderule",
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
    """Whether the first-run wizard should be offered.

    True while this installation has no users *and* no sign that a shop is
    already running on it. The first half is the real test; the second only
    stops a stranger on the shop LAN from claiming an existing shop whose user
    accounts were lost (a half-finished restore, say).

    Note which way this errs. With no users, nobody can sign in at all, so
    answering "no onboarding needed" does not protect the installation — it
    bricks it, and hands the owner a ``docker exec`` as their only way in.
    ``pointy_domain_data_exists`` is therefore built to stay quiet unless a
    person has genuinely worked in this shop.
    """
    User = get_user_model()
    return not User.objects.exists() and not pointy_domain_data_exists()


def pointy_domain_data_exists():
    """Whether a person has done shop work on this installation.

    Asks only the models on ``INITIAL_SETUP_SHOP_ACTIVITY_MODELS``; everything
    else — seeded defaults, relay-synced reference data, singletons materialised
    by boot code or a periodic task — cannot vote. See that constant for why the
    question is asked this way round.
    """
    if _shop_setup_wizard_was_completed():
        return True
    for label in INITIAL_SETUP_SHOP_ACTIVITY_MODELS:
        try:
            if apps.get_model(*label)._default_manager.all().exists():
                return True
        except Exception:
            # A model that has been renamed away, or a table that cannot be
            # read right now (mid-migration, say), is not evidence that a shop
            # is running here. The old scan answered "yes, data exists" to
            # every exception, which turned one unreadable table — or one stale
            # entry in a list — into an installation that could never be
            # onboarded, only ``docker exec``-ed into.
            continue
    return False


def _shop_setup_wizard_was_completed():
    """Whether someone has been through the first-run shop-setup wizard.

    The ``ShopSettings`` singleton itself is no evidence — boot code
    materialises it before anyone has logged in, because relay enrollment reads
    the shop name. Its ``shop_type`` is a different matter: it is blank on every
    fresh install and only the wizard fills it in, so a shop that has one has
    demonstrably been set up by a person. That makes it the one signal that
    survives a restore which brought the shop's data back without its users.
    """
    from .models import ShopSettings

    try:
        return ShopSettings.objects.exclude(shop_type="").exists()
    except Exception:
        return False


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
