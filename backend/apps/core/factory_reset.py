"""Put a shop back to the day it was installed, without reinstalling it.

Why this exists: a shop that migrates in from an old POS does it more than once.
The first import is a rehearsal — the owner finds the price list was stale, or
that half the stock counts were wrong, or simply that they would rather start
clean — and what they want next is not "delete 40,000 rows by hand" and not "a
technician with a terminal", but the button every phone has had for fifteen
years. Without it the only honest answer was to rebuild the container and
re-enrol the licence, which costs a site visit.

What it deliberately is NOT: a way to forget one bad import. It empties the
shop's whole working history — every sale ever rung, every invoice printed,
every payment recorded. There is no undo, and the only copy is whatever backup
was taken first, which is why :func:`summarize` exists and why the screen in
front of it names the counts out loud before anyone is asked to confirm.

The three-way split
-------------------
Every model in the project sits in exactly one of :data:`WIPED_MODELS`,
:data:`KEPT_MODELS` or :data:`PARTIAL_MODELS`, and
``test_every_model_is_classified`` fails the build when a new one appears in
none of them. That is the whole safety design, and it is worth saying why it is
not the obvious "delete everything except a short exempt list".

An exempt list fails silently in the direction that brings a shop down. Miss an
entry and the reset takes the licence row, or the default warehouse, or the
seeded chart of accounts with it — and the install does not come back. Miss an
entry in the *other* direction and some rows survive a reset that claimed to
clear them, which is wrong but visible and fixable. Forcing every model to be
named makes the safe failure the only one that a mistake can produce: a model
nobody classified does not get deleted, it fails the test suite instead.

(The same inversion, for the same reason, as
``roles.INITIAL_SETUP_SHOP_ACTIVITY_MODELS``. That one guards the first-run
wizard; this one guards the undo of it.)

What survives, and why
----------------------
Three kinds of row are kept, and each one would brick or badly degrade the
install if it went:

* **Identity and licence** — ``core.relayinstallation`` is the enrolment. Take
  it and the backend answers 503 to its own tills until somebody produces a
  fresh single-use licence key (see ``relay-license-enrollment``).
* **Seeded reference data** — units of measure, currencies, the default
  warehouse, the money accounts, the workflow templates. A ``migrate`` on an
  empty database creates these; nothing at runtime re-creates them, because
  they are written by data migrations that will never run again on this
  database. Deleting them is not "back to factory", it is a state no fresh
  install has ever been in.
* **Configuration and peripherals** — shop settings, printers, scales, cameras,
  price checkers, integration credentials, warehouses. This is the scope line
  the owner asked for: wipe the business, keep the shop set up. Nobody wants to
  re-pair four printers because their stock import was wrong.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from django.apps import apps
from django.contrib.auth import get_user_model
from django.core.management.color import no_style
from django.db import DEFAULT_DB_ALIAS, connections, transaction

logger = logging.getLogger(__name__)


class FactoryResetError(Exception):
    """The reset refused to run. Raised before anything has been deleted."""


#: Emptied completely. Every row in these tables exists because somebody did
#: business in this shop — or because a machine wrote a record *about* that
#: business — and a shop starting over wants none of it.
WIPED_MODELS = (
    # admin — the Django admin's own change history, which is a log of the rows
    # below and outlives them into nonsense otherwise.
    "admin.logentry",
    # ai — the assistant's conversations quote this shop's numbers back at it.
    "ai.aiconversation",
    "ai.aimessage",
    # analytics — telemetry, the activity log and the audit trail all live in
    # this one table. Cleared here for the same reason the telemetry screen can
    # clear it: it is a record of work that no longer exists.
    "analytics.analyticsevent",
    # attendance — punches and the per-employee profiles that read them. The
    # BioTime *connection* is a device credential and is kept.
    "attendance.attendanceday",
    "attendance.attendanceprofile",
    "attendance.attendancepunch",
    # balances — opening balances and adjustments on customers', suppliers' and
    # employees' accounts, and the record of which credit or cash settled which
    # debt. They belong to the parties this wipes.
    "balances.customerbalanceentry",
    "balances.customercreditapplication",
    "balances.employeebalanceallocation",
    "balances.employeebalanceentry",
    "balances.supplierbalanceentry",
    # catalog — the products themselves, their variants, units, barcodes,
    # aliases, recipes and modifier sets. The unit-of-measure and variant-option
    # vocabularies are seeded reference data and are kept.
    "catalog.billofmaterials",
    "catalog.bomline",
    "catalog.modifiergroup",
    "catalog.modifieroption",
    "catalog.product",
    "catalog.productalias",
    "catalog.productcategory",
    "catalog.productmodifiergroup",
    "catalog.productunit",
    "catalog.productunitbarcode",
    "catalog.productvariant",
    "catalog.scaleplu",
    # companion — a phone used as a till camera. Not kept despite being a
    # "peripheral": a pairing is a QR scan away, it is scoped to one register
    # session, and the pairing rows cascade off the user accounts this removes.
    "companion.companioncapturerequest",
    "companion.companiondevice",
    "companion.companionevent",
    "companion.companionpairing",
    # core — replay records for in-flight requests against rows that are going.
    "core.idempotencyrecord",
    # crm — campaigns, consent and the SMS threads with named customers.
    "crm.campaign",
    "crm.campaignrecipient",
    "crm.consentevent",
    "crm.conversation",
    "crm.conversationmessage",
    "crm.staffcommandnumber",
    # customers — customers, their cards, and the assets they left with us.
    "customers.asset",
    "customers.assetownership",
    "customers.customer",
    "customers.paymentcard",
    # discounts — rules and every redemption of them.
    "discounts.applieddiscount",
    "discounts.discountredemption",
    "discounts.discountrule",
    "discounts.discounttier",
    # documents — lifecycle events, and the numbering counters. Clearing the
    # counters is the point, not collateral: the first invoice after a reset
    # should be number 1, the way it is on a new install.
    "documents.documentevent",
    "documents.documentnumberseries",
    # employees — staff records, pay, loans and payroll runs. The admin's own
    # employee row is re-created after the wipe.
    "employees.compensationplan",
    "employees.employee",
    "employees.employeeloan",
    "employees.employeeloanpayment",
    "employees.payrolladjustment",
    "employees.payrollline",
    "employees.payrollrun",
    # expenses — the spending itself; the category list is seeded and kept.
    "expenses.expense",
    # fraud
    "fraud.fraudfinding",
    # integrations — recharges sold, the subscriber lines they were sold
    # against, and the till's record of who it looked up. The provider account
    # and its price list are credentials/config.
    "integrations.integrationfulfillment",
    "integrations.integrationsearch",
    "integrations.integrationsubscriber",
    # A provider's shelf as last read, and the catalog products it made. The
    # products go with the catalog; the next sweep reads the shelf again.
    "integrations.integrationvoucher",
    "integrations.integrationvoucherbrand",
    # The provider's own payments report as last mirrored — the agency's
    # trade, read back. The next sweep reads it again from the top; the
    # account's claim to have covered it is cleared with it (see
    # perform_factory_reset).
    "integrations.providerpayment",
    # inventory — all of it: quantities, ledgers, counts, transfers, batches,
    # serial units, consignment. The warehouses themselves are configuration.
    "inventory.consignmentagreement",
    "inventory.consignmentincident",
    "inventory.consignorpayout",
    "inventory.stockallocation",
    "inventory.stockbatch",
    "inventory.stockbatchbalance",
    "inventory.stockcount",
    "inventory.stockcountline",
    "inventory.stockcountscan",
    "inventory.stockitem",
    "inventory.stockledgerentry",
    "inventory.stockmovement",
    "inventory.stocktransfer",
    "inventory.stocktransferline",
    "inventory.stocktransferreceipt",
    "inventory.stocktransferreceiptline",
    "inventory.stockunit",
    "inventory.stockunitevent",
    "inventory.stockvaluationbin",
    # invoice_intake — photographed supplier invoices and their draft orders.
    "invoice_intake.invoiceintake",
    # messaging — sent and received SMS. The gateway is a credential.
    "messaging.deliveryreceipt",
    "messaging.inboundmessage",
    "messaging.outboundmessage",
    # migration — the imports themselves. This is what the owner is usually
    # actually asking to undo, and the identity maps are what would otherwise
    # make a second import quietly update rows that no longer exist.
    "migration.collapsecandidate",
    "migration.collapseplan",
    "migration.migrationidentitymap",
    "migration.migrationissue",
    "migration.migrationrun",
    "migration.migrationsource",
    # notifications — business alerts about numbers that are going.
    "notifications.businessnotification",
    "notifications.businessnotificationuserstate",
    # operations — jobs and everything booked against them. The workflow
    # templates that define the stages are seeded configuration.
    "operations.job",
    "operations.jobasset",
    "operations.jobmaterial",
    "operations.jobservice",
    "operations.jobstageevent",
    # payments — money taken and paid out. The card terminals are peripherals.
    "payments.payment",
    # price_checker — kiosk lookups; the kiosks themselves are devices.
    "price_checker.pricecheckevent",
    # printing — the queue and its audit trail. Printers, agents, prep stations
    # and templates are configuration and are kept.
    "printing.printauditevent",
    "printing.printjob",
    "printing.printjobevent",
    # purchasing — suppliers, orders, receipts, credit and payments. The seeded
    # "مورد غير محدد" placeholder is re-created after the wipe, because a fresh
    # install has it and a data migration is the only thing that ever writes it.
    "purchasing.purchaseline",
    "purchasing.purchaseorder",
    "purchasing.purchaseorderadjustment",
    "purchasing.purchaseorderadjustmentline",
    "purchasing.purchaseorderadjustmentreplacementline",
    "purchasing.purchaseorderauditevent",
    "purchasing.purchaseorderlandedcostentry",
    "purchasing.purchasereceipt",
    "purchasing.purchasereceiptline",
    "purchasing.supplier",
    "purchasing.suppliercredit",
    "purchasing.supplierpayment",
    "purchasing.supplierpurchaseaffinity",
    "purchasing.supplierpurchasehabit",
    "purchasing.supplierpurchaseprofile",
    # reports — saved report runs over data that no longer exists.
    "reports.reportrun",
    # sales — every sale, its lines, exchanges, trade-ins, reservations, and
    # every drawer session. The per-till register profile is configuration.
    "sales.order",
    "sales.orderadjustment",
    "sales.orderadjustmentline",
    "sales.orderexchange",
    "sales.orderline",
    "sales.orderlinemodifier",
    "sales.registercashmovement",
    "sales.registersession",
    "sales.stockreservation",
    "sales.tradein",
    # scales — queued label pushes for products that are going.
    "scales.scalepushjob",
    # sessions — every logged-in device. Deliberate: a till holding a cached
    # catalogue of deleted products must come back through the login screen,
    # not carry on. The account running the reset is signed in again at the end.
    "sessions.session",
    # treasury — counts and transfers. The money accounts are the seeded chart.
    "treasury.moneycount",
    "treasury.moneytransfer",
)

#: Never touched. The reason is part of the entry: a model is only allowed to
#: survive a "delete everything" button if somebody can say why in one line.
KEPT_MODELS = {
    # -- identity, licence, and the machinery of the reset itself -------------
    "core.relayinstallation": "The licence/enrolment. Without it the API 503s.",
    "core.relayconnectorsetuptoken": "Pairing state for the relay connector.",
    "core.systembackupschedule": "Backup destination and schedule — needed most "
    "right after a reset.",
    "core.systemmaintenancejob": "Backup/restore history; also preserved by the "
    "restore path for the same reason (backup_database.PRESERVED_TABLES).",
    # -- auth infrastructure --------------------------------------------------
    "auth.group": "The eight role groups, with their permission sets.",
    "auth.permission": "Django's permission rows; content types point at them.",
    "contenttypes.contenttype": "Schema metadata, not shop data.",
    # -- shop configuration ---------------------------------------------------
    "core.shopsettings": "The shop's own setup: name, currency, feature flags, "
    "ceilings. Wiping it would re-open the first-run wizard.",
    "inventory.warehouse": "Where the shop keeps things. Seeded with a default "
    "and a transit row that stock movements require.",
    "inventory.unitattributedefinition": "Which typed fields this trade records "
    "about a serialised article. Configuration, not stock.",
    "channels.saleschannel": "Seeded sales channels.",
    "sales.registerprofile": "Which warehouse each till sells out of, keyed on "
    "device id — a property of the counter, not of the data.",
    # -- seeded reference data (written by data migrations, never re-created) --
    "catalog.unitofmeasure": "Seeded unit vocabulary.",
    "catalog.variantoption": "Seeded variant vocabulary.",
    "catalog.variantoptionvalue": "Seeded variant vocabulary.",
    "catalog.scalebarcoderule": "Seeded scale-label layouts.",
    "customers.assettype": "Seeded asset kinds.",
    "expenses.expensecategory": "Seeded expense categories.",
    "operations.workflowtemplate": "Seeded job workflows.",
    "operations.workflowstage": "Seeded job workflow stages.",
    "treasury.moneyaccount": "Seeded money accounts — the treasury's spine.",
    "fx.currency": "Seeded currencies.",
    "fx.exchangerate": "Market rates fed by the relay, not shop data. Clearing "
    "them would leave a multi-currency shop unable to price.",
    "holidays.holiday": "Relay-synced calendar, not shop data.",
    # -- peripherals and credentials someone configured by hand ---------------
    "printing.printerprofile": "A configured printer.",
    "printing.printagent": "A print agent that registered itself on the LAN.",
    "printing.prepstation": "A kitchen/prep station. Its category routing goes "
    "with the categories (see _wiped_tables).",
    "printing.printtemplate": "Receipt/label templates.",
    "printing.printtemplateversion": "Receipt/label template history.",
    "scales.scale": "A configured weighing scale.",
    "surveillance.recorder": "A configured DVR.",
    "surveillance.camera": "A configured camera.",
    "price_checker.pricecheckerdevice": "A configured kiosk.",
    "payments.cardterminal": "A configured card terminal.",
    "messaging.messaginggateway": "SMS gateway credentials.",
    "attendance.biotimeconnection": "Attendance device credentials.",
    "integrations.integrationaccount": "Provider credentials and float.",
    "integrations.integrationoptionprice": "The provider's price list.",
    "attachments.storagevolume": "Where attachments are stored on disk.",
    "attachments.attachmentstoragestate": "Storage bookkeeping for that.",
}

#: Handled by bespoke code, because "all of it" and "none of it" are both wrong.
PARTIAL_MODELS = {
    "auth.user": "Every account goes except the administrator running the reset.",
    "attachments.attachment": "Every file goes except the shop logo, which "
    "belongs to the settings that are being kept.",
}


@dataclass
class ResetSummary:
    """What a reset would remove, or did. Counted per headline model.

    Exists so the screen can name the blast radius *before* the dialog asks, in
    the shop's own numbers rather than in table names. A button whose effect is
    off-screen is the one kind of destructive button worth refusing to build.
    """

    counts: dict = field(default_factory=dict)
    users_removed: int = 0
    admin_username: str = ""

    def as_dict(self) -> dict:
        return {
            "counts": self.counts,
            "users_removed": self.users_removed,
            "admin_username": self.admin_username,
        }


#: What the summary reports, in the order the screen shows it. Kept short on
#: purpose: this is the sentence an owner has to understand under pressure, not
#: an inventory of 122 tables.
SUMMARY_MODELS = (
    ("products", "catalog.product"),
    ("categories", "catalog.productcategory"),
    ("customers", "customers.customer"),
    ("suppliers", "purchasing.supplier"),
    ("orders", "sales.order"),
    ("purchase_orders", "purchasing.purchaseorder"),
    ("payments", "payments.payment"),
    ("stock_movements", "inventory.stockmovement"),
    ("expenses", "expenses.expense"),
    ("employees", "employees.employee"),
    ("jobs", "operations.job"),
    ("imports", "migration.migrationrun"),
)


def summarize(*, admin) -> ResetSummary:
    """Count what a reset would take, without taking any of it."""
    User = get_user_model()
    counts = {}
    for key, label in SUMMARY_MODELS:
        try:
            counts[key] = apps.get_model(*label.split("."))._default_manager.count()
        except Exception:  # noqa: BLE001 — a missing table is not a reason to
            # refuse to describe the rest of the reset.
            logger.warning("factory reset summary could not count %s", label)
            counts[key] = 0
    return ResetSummary(
        counts=counts,
        users_removed=User.objects.exclude(pk=admin.pk).count(),
        admin_username=admin.get_username(),
    )


def _model(label: str):
    return apps.get_model(*label.split("."))


#: Apps that only exist while the suite runs (``settings`` appends them under
#: ``TESTING``). They hold no shop data and never reach an installed backend, so
#: they are neither wiped nor kept — they are not classified at all.
TEST_ONLY_APP_LABELS = ("documentstestkit",)


def classified_models() -> set:
    return set(WIPED_MODELS) | set(KEPT_MODELS) | set(PARTIAL_MODELS)


def unclassified_models() -> list:
    """Models nobody has decided about. Non-empty fails the test suite."""
    known = classified_models()
    return sorted(
        f"{model._meta.app_label}.{model._meta.model_name}"
        for model in apps.get_models()
        if model._meta.app_label not in TEST_ONLY_APP_LABELS
        and f"{model._meta.app_label}.{model._meta.model_name}" not in known
    )


def wiped_tables() -> list:
    """Every table the flush truncates, in a stable order.

    Includes the auto-created many-to-many through tables, which
    ``get_models()`` does not show and which hold real data — a product's
    categories, a discount rule's targets. A through table goes when *either*
    end goes: ``printing_prepstation_categories`` survives its station but not
    the product categories it routes, and leaving those rows would fail the
    truncate on a foreign key.
    """
    tables = {_model(label)._meta.db_table for label in WIPED_MODELS}
    for model in apps.get_models(include_auto_created=True):
        if not model._meta.auto_created:
            continue
        owner = model._meta.auto_created
        owner_label = f"{owner._meta.app_label}.{owner._meta.model_name}"
        targets = {
            field.remote_field.model._meta.db_table
            for field in model._meta.local_fields
            if getattr(field, "remote_field", None) and field.remote_field.model
        }
        if owner_label in set(WIPED_MODELS) or targets & tables:
            tables.add(model._meta.db_table)
    return sorted(tables)


def surviving_references_to_wiped_tables() -> list:
    """Foreign keys that would make the truncate fail — or, worse, cascade.

    The guard is the same shape as ``backup_database._assert_exclusions_are_safe``
    and exists for the same reason: a list of tables is only safe while nothing
    that is *kept* points into it. Postgres would refuse the ``TRUNCATE`` at
    runtime, which is a safe failure but a late one — this makes it a test
    failure at the moment the offending foreign key is added.
    """
    wiped = set(wiped_tables())
    offenders = []
    for model in apps.get_models(include_auto_created=True):
        if not model._meta.managed or model._meta.db_table in wiped:
            continue
        for field_ in model._meta.local_fields:
            remote = getattr(field_, "remote_field", None)
            if remote is None or remote.model is None:
                continue
            if remote.model._meta.db_table in wiped:
                offenders.append(
                    f"{model._meta.db_table}.{field_.column} -> "
                    f"{remote.model._meta.db_table}"
                )
    return sorted(offenders)


def perform_factory_reset(*, admin, connection=None) -> ResetSummary:
    """Empty the shop. Returns what went.

    Ordering is not arbitrary:

    1. Note down the files on disk, while the rows that name them still exist.
       Nothing else can find an uploaded legacy database or an attachment's
       bytes once the rows are gone.
    2. Then one ``TRUNCATE`` over every wiped table, with ``RESTART IDENTITY``.
       One statement rather than 122 deletes: it is a single brief lock, it
       cannot half-succeed, and resetting the sequences is part of the promise —
       the first product after a reset is id 1.
    3. Then the accounts, by ORM delete, so their cascades run.
    4. Then put back the handful of rows a fresh install has and a truncate does
       not: the placeholder supplier, the admin's employee record.
    5. Only once all of that has *committed*, delete the files.

    Step 5 is last for a reason worth stating. Deleting the bytes first would
    mean a reset that then failed — a locked table, a constraint, a dropped
    connection — had destroyed a shop's scanned invoices and its uploaded
    legacy database while leaving every row in place: data loss with no reset
    to show for it. This way the worst case is the harmless one, orphaned files
    on disk after a crash, which cost space and nothing else.

    Truncate is invisible to Django's signals, which is why the caller bumps the
    state versions and catalogue stamp afterwards rather than trusting the
    ``post_delete`` wiring to have noticed.
    """
    connection = connection or connections[DEFAULT_DB_ALIAS]
    User = get_user_model()

    if not admin or not admin.is_authenticated:
        raise FactoryResetError("A factory reset needs an authenticated administrator.")

    summary = summarize(admin=admin)

    doomed_files = _stored_files_to_discard()

    with transaction.atomic():
        statements = connection.ops.sql_flush(
            no_style(),
            wiped_tables(),
            reset_sequences=True,
            allow_cascade=False,
        )
        with connection.cursor() as cursor:
            if connection.vendor == "postgresql":
                # Django declares its foreign keys DEFERRABLE INITIALLY
                # DEFERRED, so every row written earlier in this transaction
                # leaves a pending trigger event behind it — and Postgres
                # refuses to TRUNCATE a table that has any. Under
                # ATOMIC_REQUESTS that is not a corner case: anything the
                # request touched before reaching this line is enough.
                # Forcing the pending checks to run now clears them, and they
                # pass, because the rows were valid when they were written.
                cursor.execute("SET CONSTRAINTS ALL IMMEDIATE")
            for sql in statements:
                cursor.execute(sql)

        # After the truncate, so the collector has almost nothing left to walk.
        User.objects.exclude(pk=admin.pk).delete()

        # The one partial table that cannot be truncated: the shop logo belongs
        # to the settings, and the settings stay. Its bytes were left out of
        # the sweep above for the same reason.
        from apps.attachments.models import Attachment

        Attachment.objects.exclude(role=Attachment.Role.SHOP_LOGO).delete()

        # The provider accounts stay, but their stamps saying "the mirrored
        # payments report is whole from here to there" described rows that
        # are gone. Left in place, the next read would believe a stretch it
        # never read again.
        from apps.integrations.models import IntegrationAccount

        IntegrationAccount.objects.update(
            payments_synced_at=None, payments_covered_since=None
        )

        _reseed(admin=admin)

    _delete_quietly(doomed_files)
    return summary


def _stored_files_to_discard() -> list:
    """Everything on disk that belongs to a row this reset is about to take.

    Resolved now and deleted later (see :func:`perform_factory_reset`), because
    the paths are only knowable while the rows exist and the bytes must only go
    once the rows actually have.

    The shop logo is excluded: it belongs to the settings, and the settings
    stay. The migration staging files are included under both their recorded
    and their derived names, the way ``migration.storage.purge_source_files``
    does — preparation can write a file and then fail before recording it.
    """
    from apps.attachments.models import Attachment
    from apps.migration.models import MigrationSource
    from apps.migration.storage import (
        prepared_name,
        prepared_path,
        staged_path,
        working_name,
    )
    from apps.migration.storage import _resolve as resolve_staging_path

    paths = []
    for source in MigrationSource.objects.all().iterator():
        try:
            paths.extend(
                [
                    staged_path(source),
                    prepared_path(source),
                    resolve_staging_path(working_name(source.pk)),
                    resolve_staging_path(prepared_name(source.pk)),
                ]
            )
        except Exception:  # noqa: BLE001 — a path this code cannot resolve is a
            # file it cannot delete, which is disk, not data.
            logger.warning(
                "factory reset could not resolve files for migration source %s",
                source.pk,
            )

    attachments = Attachment.objects.exclude(role=Attachment.Role.SHOP_LOGO)
    for attachment in attachments.iterator():
        try:
            paths.append(attachment.absolute_path)
        except Exception:  # noqa: BLE001
            logger.warning(
                "factory reset could not resolve the file for attachment %s",
                attachment.pk,
            )
    return paths


def _delete_quietly(paths) -> None:
    """Best-effort, always. The rows are already gone and committed; a file
    that was missing, or a volume that is briefly read-only, is not a reason to
    report a reset as failed after it has succeeded."""
    for path in paths:
        if path is None:
            continue
        try:
            path.unlink()
        except OSError:
            continue


def _reseed(*, admin) -> None:
    """Put back what a ``migrate`` on an empty database would have left.

    Only two things qualify. Everything else a fresh install seeds lives in a
    kept model and was never touched.
    """
    from apps.employees.services import ensure_employee_for_user
    from apps.purchasing.models import Supplier

    # Written by purchasing migration 0004 and never again. Nothing looks it up
    # by name at runtime, but a fresh install has the row and "factory reset"
    # should mean the same database a fresh install has.
    Supplier.objects.get_or_create(
        name="مورد غير محدد",
        defaults={
            "notes": "تم إنشاؤه لربط أوامر الشراء القديمة التي لم يكن لها مورد.",
        },
    )
    ensure_employee_for_user(admin, created_by=admin)


def invalidate_caches() -> None:
    """Tell every cache and every connected client that the shop changed.

    Necessary because the wipe is a ``TRUNCATE``: no ``post_delete`` fires, so
    none of the counters that normally move on a write have moved. A till whose
    catalogue stamp still matches would go on serving deleted products out of
    its own cache until something else happened to bump it.
    """
    from apps.catalog.cache import bump_catalog_version
    from apps.core import state_version
    from apps.core.caching import bump_perm_version

    for domain in state_version.DOMAINS:
        if domain.external or domain.per_user:
            continue
        try:
            state_version.bump(domain.name)
        except Exception:  # noqa: BLE001
            logger.warning("factory reset could not bump state domain %s", domain.name)
    for bump in (bump_catalog_version, bump_perm_version):
        try:
            bump()
        except Exception:  # noqa: BLE001
            logger.warning("factory reset could not bump %s", bump.__name__)
    try:
        from apps.discounts.cache import bump_rules_version

        bump_rules_version()
    except Exception:  # noqa: BLE001
        logger.warning("factory reset could not bump the discount rules version")
