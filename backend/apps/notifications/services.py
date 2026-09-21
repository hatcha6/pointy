import logging
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.db.models import (
    Count,
    DecimalField,
    F,
    OuterRef,
    Prefetch,
    Q,
    Subquery,
    Sum,
    Value,
)
from django.db.models.functions import Coalesce
from django.utils import timezone

from apps.catalog.models import Product
from apps.core.backup import backup_health
from apps.core.models import ShopSettings
from apps.core.dispatch import enqueue_best_effort
from apps.core.roles import user_is_manager
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockBatch, StockItem
from apps.payments.models import Payment
from apps.printing.models import PrintAgent, PrintJob
from apps.purchasing.models import PurchaseOrder, SupplierPayment
from apps.sales.models import (
    Order,
    OrderAdjustment,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
    SOLD_COST_EXPRESSION,
    SOLD_REVENUE_EXPRESSION,
)

from .cache import bump_notifications_version, bump_user_notifications_version
from .models import BusinessNotification, BusinessNotificationUserState

logger = logging.getLogger(__name__)

MANAGED_CODES = (
    "inventory.out_of_stock",
    "inventory.low_stock",
    "inventory.position_untrusted",
    "inventory.expiring_batch",
    # Phase D. Three things a shop that identifies its stock has to be told
    # about without going looking: goods on the shelf that nothing has named,
    # a claim on somebody else's property that nobody has priced, and money in
    # the drawer that belongs to a consignor who never came back.
    "inventory.missing_identifiers",
    "inventory.open_custody_claims",
    "inventory.unclaimed_payouts",
    "purchasing.overdue_order",
    "printing.failed_job",
    "printing.stale_agent",
    "sales.register_variance",
    "sales.negative_margin",
    "fraud.suspected_cashier_activity",
    # Resale providers. Three failures that mean three different things: a
    # customer who paid and got nothing, cash taken outside Pointy, and a
    # float that disagrees with our arithmetic for a reason we cannot name.
    "integrations.unperformed_recharge",
    "integrations.offbook_recharge",
    "integrations.float_drift",
    # A write went out and its answer never came back. The most urgent of the
    # four, because it is the only one where nobody yet knows whether money
    # moved — and where the wrong reaction (try again) spends it twice.
    "integrations.unresolved_recharge",
    # The float is nearly out. The one alert here that arrives before a sale
    # has failed rather than after — see _low_float_notification.
    "integrations.low_float",
    "discounts.expiring_rule",
    "employees.payroll_ready",
    "operations.backend_error",
    "operations.backup_unhealthy",
)
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
NOTIFICATION_AUDIENCE_RULES = {
    "inventory.out_of_stock": {
        "permissions": ("inventory.view_stockitem", "inventory.view_stockmovement"),
        "manager_only": True,
    },
    "inventory.low_stock": {
        "permissions": ("inventory.view_stockitem", "inventory.view_stockmovement"),
        "manager_only": True,
    },
    "inventory.position_untrusted": {
        "permissions": ("inventory.view_stockitem", "inventory.view_stockmovement"),
        "manager_only": True,
    },
    "inventory.expiring_batch": {
        "permissions": ("inventory.view_stockitem", "inventory.view_stockmovement"),
        "manager_only": True,
    },
    "inventory.missing_identifiers": {
        "permissions": ("inventory.view_stockunit",),
        "manager_only": False,
    },
    "inventory.open_custody_claims": {
        "permissions": ("inventory.view_consignment_liability",),
        "manager_only": True,
    },
    "inventory.unclaimed_payouts": {
        "permissions": ("inventory.view_consignment_liability",),
        "manager_only": True,
    },
    "purchasing.overdue_order": {
        "permissions": ("purchasing.view_purchaseorder", "purchasing.view_supplier"),
        "manager_only": True,
    },
    "printing.failed_job": {
        "permissions": ("printing.view_printjob",),
        "manager_only": False,
    },
    "printing.stale_agent": {
        "permissions": ("printing.view_printagent",),
        "manager_only": True,
    },
    "sales.register_variance": {
        "permissions": ("sales.view_registersession",),
        "manager_only": True,
    },
    "sales.negative_margin": {
        "permissions": ("sales.view_order",),
        "manager_only": True,
    },
    "fraud.suspected_cashier_activity": {
        "permissions": ("fraud.view_fraudfinding", "analytics.view_analyticsevent"),
        "manager_only": True,
    },
    # Resale providers. These had no entry at all until the float warning was
    # added, which meant the four recharge alerts were generated, stored, swept
    # — and shown to nobody, because _codes_for_user only returns codes that
    # appear here. A code with no rule is invisible, not public.
    "integrations.unperformed_recharge": {
        # A customer paid and got nothing. The till is where that is fixed —
        # charge it again or refund it — so the cashier holding the counter
        # sees it, not only the owner who may be nowhere near the shop.
        "permissions": ("integrations.use_integrations",),
        "manager_only": False,
    },
    "integrations.unresolved_recharge": {
        # Nobody yet knows whether money moved, and the one safe action is to
        # read the provider's own log. Manager work: the wrong reaction at the
        # till (send it again) is exactly what spends it twice.
        "permissions": ("integrations.manage_integrations",),
        "manager_only": True,
    },
    # NB: nothing generates this one yet. ``reconcile_account`` returns the
    # orphan purchases under ``off_book`` and the code has been declared in
    # MANAGED_CODES since the feature shipped, but no builder turns them into
    # notifications. The rule is here so the two lists agree and so the day a
    # builder is written it is seen rather than silently swallowed.
    "integrations.offbook_recharge": {
        "permissions": ("integrations.manage_integrations",),
        "manager_only": True,
    },
    "integrations.float_drift": {
        "permissions": ("integrations.manage_integrations",),
        "manager_only": True,
    },
    "integrations.low_float": {
        # Whoever can refill it. Deliberately not manager-only and deliberately
        # not gated on manage_integrations alone: the person who walks to the
        # provider's office with the money is the accountant or the buyer, and
        # they are the one who needs the day's notice.
        "permissions": (
            "integrations.manage_integrations",
            "integrations.record_integration_topup",
        ),
        "manager_only": False,
    },
    "discounts.expiring_rule": {
        "permissions": ("discounts.view_discountrule",),
        "manager_only": True,
    },
    "employees.payroll_ready": {
        "permissions": ("employees.view_payrollrun", "employees.approve_payrollrun"),
        "manager_only": True,
    },
    "operations.backup_unhealthy": {
        "permissions": ("core.change_shopsettings",),
        "manager_only": True,
    },
}


def sync_business_notifications(now=None):
    now = now or timezone.now()
    desired = []
    desired.extend(_inventory_notifications(now))
    desired.extend(_expiry_notifications(now))
    desired.extend(_identified_stock_notifications(now))
    desired.extend(_purchasing_notifications(now))
    desired.extend(_printing_notifications(now))
    desired.extend(_sales_notifications(now))
    desired.extend(_fraud_notifications(now))
    desired.extend(_integration_notifications(now))
    desired.extend(_discount_notifications(now))
    desired.extend(_payroll_notifications(now))
    desired.extend(_backup_notifications(now))

    fingerprints = set()
    changed = 0
    with transaction.atomic():
        for spec in desired:
            fingerprints.add(spec["fingerprint"])
            if _upsert_notification(spec, now):
                changed += 1

        changed += (
            BusinessNotification.objects.filter(
                code__in=MANAGED_CODES,
                status=BusinessNotification.Status.ACTIVE,
            )
            .exclude(fingerprint__in=fingerprints)
            .update(
                status=BusinessNotification.Status.RESOLVED,
                resolved_at=now,
                last_seen_at=now,
            )
        )
    if changed:
        # Only a material change orphans feed ETags — the last_seen_at-only
        # refresh above must keep every device 304ing.
        bump_notifications_version()

    return {
        "active": BusinessNotification.objects.filter(
            status=BusinessNotification.Status.ACTIVE,
        ).count(),
        "generated": len(desired),
    }


# The feed is recomputed on a Celery beat (notifications.sync_business_notifications).
# Reads *also* top it up inline, but no more than once per this window (seconds),
# so a fleet of devices polling the bell/badge can't each trigger a fresh
# whole-catalog + all-time recompute. Tunable via settings; <= 0 disables the
# throttle (recompute on every read, the old behaviour).
INLINE_SYNC_THROTTLE_SECONDS = 300
INLINE_SYNC_THROTTLE_CACHE_KEY = "notifications:inline-sync:lock"


def maybe_sync_business_notifications(now=None):
    """Advance the feed out of band, at most once per throttle window, WITHOUT
    ever running the recompute on the request path.

    The Celery beat is the primary refresher. This top-up hands a recompute to
    the worker so (a) a fresh deploy primes the table before the beat's first
    tick and (b) the feed keeps advancing between ticks — but the bell/badge
    poll from every signed-in device never itself pays (or waits on) the full
    whole-catalog scan, which was ~1300 queries and several seconds inline.
    ``cache.add`` is atomic on the Redis backend, so concurrent polls collapse
    into a single enqueue per window.

    Falls back to an inline recompute only when the broker can't be reached
    (Celery not configured / worker+broker down), so the feed still advances in
    that degraded state. Returns the sync result dict only when it recomputed
    inline (throttle disabled or broker unreachable), else None. When the cache
    itself is unreachable the top-up is skipped entirely — see below.
    """
    throttle_seconds = getattr(
        settings,
        "POINTY_NOTIFICATION_INLINE_SYNC_THROTTLE_SECONDS",
        INLINE_SYNC_THROTTLE_SECONDS,
    )
    if throttle_seconds <= 0:
        # Escape hatch: recompute inline on every read (e.g. a deployment with no
        # running beat/worker that accepts the per-read cost).
        return sync_business_notifications(now=now)
    # Only the first caller in the window sets the key and proceeds; the rest see
    # the key already present and short-circuit, serving the last-computed table.
    # No usable Redis means no usable Celery either (same server is the broker),
    # so the fallback below cannot help — and running the whole-catalog recompute
    # inline on every poll from every device would turn a cache outage into a
    # database one. Skip the top-up instead: the bell keeps serving the
    # last-computed feed, stale but present, until Redis comes back.
    try:
        claimed = cache.add(
            INLINE_SYNC_THROTTLE_CACHE_KEY, "1", timeout=throttle_seconds
        )
    except Exception:  # noqa: BLE001 — redis down/unreachable
        logger.warning(
            "notification sync throttle unavailable; skipping the top-up",
            exc_info=True,
        )
        return None
    if not claimed:
        return None
    from .tasks import sync_business_notifications_task

    # Bounded and best-effort: enqueuing a recompute must never add latency to
    # (or hang) the bell poll every device runs. A broker that accepts the
    # connection and then stops answering is the case a bare try/except cannot
    # see, so the deadline lives in the connection.
    if enqueue_best_effort(sync_business_notifications_task):
        return None
    return sync_business_notifications(now=now)


def visible_notifications_for_user(user):
    queryset = BusinessNotification.objects.filter(
        status=BusinessNotification.Status.ACTIVE,
    )
    codes = _codes_for_user(user)
    if not codes:
        return queryset.none()
    # Scope the prefetch to the viewer. ``_state_for_user`` is the only reader
    # of these rows and it wants exactly one of them — this user's — yet an
    # unfiltered prefetch loads every member of staff's state for every alert
    # on the feed. That is rows the bell poll pays for and throws away, and it
    # grows with headcount, a dimension the request does not depend on: at a
    # full 50-alert page it is 50 x staff rows to answer 50 questions. The
    # statement count is identical either way, which is why a query-count test
    # cannot see it (see ``test_feed_state_rows_do_not_grow_with_staff_count``).
    return queryset.filter(code__in=codes).prefetch_related(
        Prefetch(
            "user_states",
            queryset=BusinessNotificationUserState.objects.filter(user=user),
        )
    )


def notification_is_hidden_for_user(notification, user, now=None):
    state = _state_for_user(notification, user)
    if state is None:
        return False, ""
    if state.acknowledged_at is not None:
        return True, "acknowledged"
    now = now or timezone.now()
    if state.snoozed_until is not None and state.snoozed_until > now:
        return True, "snoozed"
    return False, ""


def notification_state_for_user(notification, user):
    return _state_for_user(notification, user)


def acknowledge_notification(notification, user, now=None):
    now = now or timezone.now()
    state, _ = BusinessNotificationUserState.objects.get_or_create(
        notification=notification,
        user=user,
    )
    state.acknowledged_at = now
    state.snoozed_until = None
    state.save(update_fields=["acknowledged_at", "snoozed_until", "updated_at"])
    bump_user_notifications_version(user.pk)
    return state


def snooze_notification(notification, user, *, duration, now=None):
    now = now or timezone.now()
    state, _ = BusinessNotificationUserState.objects.get_or_create(
        notification=notification,
        user=user,
    )
    state.acknowledged_at = None
    state.snoozed_until = now + duration
    state.save(update_fields=["acknowledged_at", "snoozed_until", "updated_at"])
    bump_user_notifications_version(user.pk)
    return state


def restore_notification(notification, user):
    BusinessNotificationUserState.objects.filter(
        notification=notification,
        user=user,
    ).delete()
    bump_user_notifications_version(user.pk)


def restore_notifications_for_user(user, queryset):
    notification_ids = list(queryset.values_list("id", flat=True))
    if not notification_ids:
        return 0
    deleted, _ = BusinessNotificationUserState.objects.filter(
        user=user,
        notification_id__in=notification_ids,
    ).delete()
    bump_user_notifications_version(user.pk)
    return deleted


def acknowledge_notifications_for_user(user, queryset, now=None):
    now = now or timezone.now()
    notification_ids = list(queryset.values_list("id", flat=True))
    if not notification_ids:
        return 0
    # A constant three statements — SELECT existing, UPDATE them, INSERT the
    # rest — inside one transaction, rather than a get_or_create per
    # notification plus a trailing bulk_update. The old loop issued O(N)
    # round-trips and left the writes non-atomic: a "hide all" that lost its
    # connection midway (e.g. the server restarting under it) could commit a
    # partial dismissal. This keeps the whole batch all-or-nothing.
    with transaction.atomic():
        existing_ids = set(
            BusinessNotificationUserState.objects.filter(
                user=user,
                notification_id__in=notification_ids,
            ).values_list("notification_id", flat=True)
        )
        if existing_ids:
            BusinessNotificationUserState.objects.filter(
                user=user,
                notification_id__in=existing_ids,
            ).update(acknowledged_at=now, snoozed_until=None, updated_at=now)
        missing_states = [
            BusinessNotificationUserState(
                notification_id=notification_id,
                user=user,
                acknowledged_at=now,
                snoozed_until=None,
            )
            for notification_id in notification_ids
            if notification_id not in existing_ids
        ]
        if missing_states:
            # ignore_conflicts covers the race where a concurrent read or the
            # sync beat created the state between the SELECT above and here.
            BusinessNotificationUserState.objects.bulk_create(
                missing_states,
                ignore_conflicts=True,
            )
    bump_user_notifications_version(user.pk)
    return len(notification_ids)


def _inventory_notifications(now):
    """Stock alerts, guarded against a shop that has no real stock position.

    A shop that never counted its opening stock in — or that sells with
    overselling allowed — drifts every tracked item below zero. Alerting once
    per variant then produces thousands of rows that are all the same fact:
    *the book position is fiction*. One field shop reached 11,884 active
    out-of-stock alerts, 88% of everything the notification system had ever
    said, and the register-variance and fraud alerts underneath were never
    seen. Severity means nothing when almost everything is critical.

    So three guards, in order:

    * A **negative** quantity is a data-integrity problem, not an empty shelf —
      you cannot sell what you never received. Those roll up into a single
      ``inventory.position_untrusted`` alert instead of one alert each.
    * When most of what we track has gone negative, the position as a whole is
      untrustworthy: emit only the roll-up and skip the per-variant alerts
      entirely, because none of them can be believed.
    * Whatever survives is capped, so no single sync can flood the centre.

    Out-of-stock itself is a WARNING, not CRITICAL. An empty shelf is a normal
    trading condition; critical is for money going missing and systems failing.
    """
    ratio_gate = _setting_ratio("POINTY_INVENTORY_UNTRUSTED_RATIO", 0.5)
    min_items = max(
        int(getattr(settings, "POINTY_INVENTORY_UNTRUSTED_MIN_ITEMS", 10)), 1
    )
    max_items = max(int(getattr(settings, "POINTY_INVENTORY_ALERT_MAX_ITEMS", 50)), 0)

    tracked = StockItem.objects.filter(
        variant__is_active=True,
        variant__product__is_active=True,
    )
    tracked_count = tracked.count()
    if not tracked_count:
        return []

    negative_count = tracked.filter(quantity_on_hand__lt=0).count()
    non_positive_count = tracked.filter(quantity_on_hand__lte=0).count()
    # Keyed on *negatives*, not on everything non-positive: a shop can honestly
    # have a lot of empty shelves, and silencing it for that would hide the very
    # thing it asked to be told. Only an impossible position — sold what was
    # never received — says the numbers themselves cannot be believed. The
    # minimum sample stops a two-item catalog from tripping the ratio on one row.
    position_untrusted = (
        tracked_count >= min_items and (negative_count / tracked_count) >= ratio_gate
    )

    specs = []
    if negative_count:
        specs.append(
            _spec(
                code="inventory.position_untrusted",
                category=BusinessNotification.Category.INVENTORY,
                severity=BusinessNotification.Severity.WARNING,
                # Shop-wide, so a single stable fingerprint: this is one
                # condition, and it resolves when the last negative clears.
                fingerprint="inventory.position_untrusted:shop",
                entity_type="inventory.stockitem",
                entity_id="",
                payload={
                    "count": negative_count,
                    "quantity": negative_count,
                    "tracked_count": tracked_count,
                    "non_positive_count": non_positive_count,
                    "suppressing_item_alerts": position_untrusted,
                },
            )
        )

    if position_untrusted:
        # Every per-variant alert would be derived from the same broken data.
        return specs

    # Only rows that can alert leave the DB: on a 30k-item catalog a handful
    # are at/below reorder, but this used to materialize every StockItem.
    stock = (
        tracked.select_related("variant", "variant__product")
        .filter(
            Q(quantity_on_hand__lte=0)
            | Q(quantity_on_hand__lte=F("reorder_level"))
        )
        .order_by("quantity_on_hand", "variant_id")
    )

    item_specs = []
    for item in stock:
        if item.quantity_on_hand < 0:
            # Covered by the roll-up above.
            continue
        if item.quantity_on_hand == 0:
            item_specs.append(
                _spec(
                    code="inventory.out_of_stock",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.WARNING,
                    fingerprint=f"inventory.out_of_stock:variant:{item.variant_id}",
                    entity_type="catalog.productvariant",
                    entity_id=str(item.variant_id),
                    payload=_stock_payload(item),
                )
            )
        elif item.quantity_on_hand <= item.reorder_level:
            item_specs.append(
                _spec(
                    code="inventory.low_stock",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.WARNING,
                    fingerprint=f"inventory.low_stock:variant:{item.variant_id}",
                    entity_type="catalog.productvariant",
                    entity_id=str(item.variant_id),
                    payload=_stock_payload(item),
                )
            )

    if max_items and len(item_specs) > max_items:
        dropped = len(item_specs) - max_items
        item_specs = item_specs[:max_items]
        logger.info(
            "inventory alerts capped at %s; %s further items not raised",
            max_items,
            dropped,
        )
    specs.extend(item_specs)
    return specs


def _setting_ratio(name, default):
    """A 0..1 settings knob that refuses to silently become a no-op.

    A misconfigured 0 would make every shop look untrusted and a misconfigured
    2 would disable the guard, so clamp rather than trust the value.
    """
    try:
        value = float(getattr(settings, name, default))
    except (TypeError, ValueError):
        return default
    return min(max(value, 0.0), 1.0)


def _expiry_notifications(now):
    specs = []
    today = timezone.localdate(now)
    alert_window_days = max(
        getattr(settings, "POINTY_EXPIRY_ALERT_WINDOW_DAYS", 30),
        0,
    )
    window_end = today + timedelta(days=alert_window_days)
    # A lot's quantity moved onto its balances when a lot stopped being a place
    # (§4.7), so "how much of this is still on a shelf" is the sum across them —
    # and the supplier now comes off the lot itself, which is where a fact about
    # a factory run belongs. Annotated rather than walked so a shop with a long
    # expiry tail does not pay a query per lot.
    batches = (
        StockBatch.objects.select_related("variant", "variant__product", "supplier")
        .annotate(
            on_hand=Coalesce(
                Sum("balances__remaining_quantity"),
                Value(Decimal("0")),
                output_field=DecimalField(max_digits=14, decimal_places=3),
            )
        )
        .filter(
            Q(variant__product__tracks_expiry=True)
            # Lot-tracked products carry expiry as a property of the cohort
            # rather than of the product, so they alert on the same window
            # without anyone having to also tick ``tracks_expiry``. Turning that
            # flag off still silences a product that merely tracked dates, which
            # is what it has always meant.
            | Q(
                variant__product__tracking_mode__in=[
                    Product.TrackingMode.BATCH,
                    Product.TrackingMode.SERIAL_BATCH,
                ]
            ),
            on_hand__gt=0,
            expiry_date__isnull=False,
            expiry_date__lte=window_end,
            variant__is_active=True,
            variant__product__is_active=True,
        )
        .exclude(status=StockBatch.Status.QUARANTINED)
        .order_by("expiry_date", "id")
    )
    for batch in batches:
        days = (batch.expiry_date - today).days
        severity = BusinessNotification.Severity.INFO
        if days <= 1:
            severity = BusinessNotification.Severity.CRITICAL
        elif days <= 7:
            severity = BusinessNotification.Severity.WARNING
        supplier_name = batch.supplier.name if batch.supplier_id else ""
        specs.append(
            _spec(
                code="inventory.expiring_batch",
                category=BusinessNotification.Category.INVENTORY,
                severity=severity,
                fingerprint=f"inventory.expiring_batch:stockbatch:{batch.pk}",
                entity_type="inventory.stockbatch",
                entity_id=str(batch.pk),
                payload={
                    "product_name": batch.variant.full_name,
                    "sku": batch.variant.sku,
                    "quantity": float(batch.on_hand),
                    "expiry_date": batch.expiry_date.isoformat(),
                    "days": max(days, 0),
                    "batch_code": batch.display_code,
                    "supplier_name": supplier_name,
                    "count": 1,
                },
            )
        )
    return specs


def _identified_stock_notifications(now):
    """Phase D's three: unnamed goods, unpriced claims, uncollected money.

    All three are things a shop only discovers by opening a screen it has no
    reason to open. The worklist is the one a till enforces — a unit with no
    identifier cannot be sold — so a shop that ignores it discovers the
    problem at a counter with a customer waiting.
    """
    from apps.inventory import consignment as consignment_figures
    from apps.inventory.models import StockUnit

    specs = []

    owing = StockUnit.objects.filter(
        is_identified=False, status__in=StockUnit.LIVE_STATUSES
    ).count()
    if owing:
        specs.append(
            _spec(
                code="inventory.missing_identifiers",
                category=BusinessNotification.Category.INVENTORY,
                severity=BusinessNotification.Severity.WARNING,
                fingerprint="inventory.missing_identifiers",
                entity_type="inventory.stockunit",
                entity_id="",
                payload={"count": owing},
            )
        )

    open_incidents = consignment_figures.open_incidents()
    unassessed = open_incidents.filter(is_assessed=False).count()
    open_count = open_incidents.count()
    if open_count:
        specs.append(
            _spec(
                code="inventory.open_custody_claims",
                category=BusinessNotification.Category.INVENTORY,
                # An unpriced claim is the urgent half: it is an argument that
                # has not been had yet, and it gets harder with every week.
                severity=(
                    BusinessNotification.Severity.WARNING
                    if unassessed
                    else BusinessNotification.Severity.INFO
                ),
                fingerprint="inventory.open_custody_claims",
                entity_type="inventory.consignmentincident",
                entity_id="",
                payload={
                    "count": open_count,
                    "unassessed": unassessed,
                    "value": float(consignment_figures.consignor_claims_open()),
                },
            )
        )

    settings_row = ShopSettings.load()
    reminder_days = int(
        getattr(settings_row, "consignment_unclaimed_payout_reminder_days", 0) or 0
    )
    if reminder_days > 0:
        cutoff = now - timedelta(days=reminder_days)
        stale = [
            unit
            for unit in consignment_figures.payable_units()
            if unit.sold_at is not None and unit.sold_at <= cutoff
        ]
        if stale:
            specs.append(
                _spec(
                    code="inventory.unclaimed_payouts",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.INFO,
                    fingerprint="inventory.unclaimed_payouts",
                    entity_type="inventory.stockunit",
                    entity_id="",
                    payload={
                        "count": len(stale),
                        "days": reminder_days,
                        "value": float(
                            sum(
                                (
                                    consignment_figures.consignor_payout_due(unit)
                                    for unit in stale
                                ),
                                Decimal("0.00"),
                            )
                        ),
                    },
                )
            )
    return specs


def _purchasing_notifications(now):
    specs = []
    today = timezone.localdate()
    orders = (
        PurchaseOrder.objects.exclude(status=PurchaseOrder.Status.CANCELLED)
        .annotate(
            notification_paid_total=Coalesce(
                Sum(
                    "supplier_payments__amount",
                    filter=~Q(
                        supplier_payments__method=SupplierPayment.Method.SUPPLIER_CREDIT,
                    ),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            notification_credit_total=Coalesce(
                Sum(
                    "supplier_payments__amount",
                    filter=Q(
                        supplier_payments__method=SupplierPayment.Method.SUPPLIER_CREDIT,
                    ),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
        )
        # Overdue + unpaid decided in SQL: only actual alerts leave the DB,
        # not every non-cancelled PO ever recorded.
        .filter(
            due_date__isnull=False,
            due_date__lt=today,
            total__gt=F("notification_paid_total") + F("notification_credit_total"),
        )
        .select_related("supplier")
    )
    for order in orders:
        balance = max(
            order.total - order.notification_paid_total - order.notification_credit_total,
            Decimal("0.00"),
        )
        if balance <= 0:
            continue
        specs.append(
            _spec(
                code="purchasing.overdue_order",
                category=BusinessNotification.Category.PURCHASING,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint=f"purchasing.overdue_order:{order.pk}",
                entity_type="purchasing.purchaseorder",
                entity_id=str(order.pk),
                payload={
                    "order_number": order.order_number,
                    "supplier_name": order.supplier.name,
                    "due_date": order.due_date.isoformat(),
                    "amount": _money(balance),
                    "count": 1,
                },
            )
        )
    return specs


def _printing_notifications(now):
    specs = []
    failed_jobs = PrintJob.objects.select_related("order").filter(
        status=PrintJob.Status.FAILED,
    )
    for job in failed_jobs:
        specs.append(
            _spec(
                code="printing.failed_job",
                category=BusinessNotification.Category.PRINTING,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint=f"printing.failed_job:{job.pk}",
                entity_type="printing.printjob",
                entity_id=str(job.pk),
                payload={
                    "receipt_number": job.order.receipt_number if job.order_id else "",
                    "message": job.error_message,
                    "failed_at": job.failed_at.isoformat() if job.failed_at else None,
                    "count": 1,
                },
            )
        )

    stale_before = now - timedelta(minutes=15)
    queued_count = PrintJob.objects.filter(status=PrintJob.Status.QUEUED).count()
    stale_agents = PrintAgent.objects.filter(is_active=True).filter(
        Q(last_seen_at__lt=stale_before) | Q(last_seen_at__isnull=True)
    )
    for agent in stale_agents:
        specs.append(
            _spec(
                code="printing.stale_agent",
                category=BusinessNotification.Category.PRINTING,
                severity=(
                    BusinessNotification.Severity.CRITICAL
                    if queued_count
                    else BusinessNotification.Severity.WARNING
                ),
                fingerprint=f"printing.stale_agent:{agent.pk}",
                entity_type="printing.printagent",
                entity_id=str(agent.pk),
                payload={
                    "agent_name": agent.name,
                    "queued_count": queued_count,
                    "count": 1,
                },
            )
        )
    return specs


def _sales_notifications(now):
    specs = []
    # cash_variance is a 4-aggregate Python property (payments, refunds,
    # pay-ins, pay-outs) — computing it per closed session used to cost
    # 1 + 4N queries over all-time history. The same filtered sums as
    # correlated subqueries decide "has variance" in one query; each relation
    # gets its own subquery because joining them would fan out the sums.
    def _session_sum(queryset, field="amount"):
        return Coalesce(
            Subquery(
                queryset.values("register_session")
                .annotate(total=Sum(field))
                .values("total")[:1]
            ),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )

    sessions = (
        RegisterSession.objects.filter(
            status=RegisterSession.Status.CLOSED,
            closing_cash__isnull=False,
        )
        .annotate(
            variance_cash_sales=_session_sum(
                Payment.objects.filter(
                    register_session=OuterRef("pk"),
                    method=Payment.Method.CASH,
                    amount__gt=0,
                )
            ),
            variance_refunds=_session_sum(
                OrderAdjustment.objects.filter(register_session=OuterRef("pk")),
                "cash_amount",
            ),
            variance_pay_in=_session_sum(
                RegisterCashMovement.objects.filter(
                    register_session=OuterRef("pk"),
                    movement_type=RegisterCashMovement.MovementType.PAY_IN,
                )
            ),
            variance_pay_out=_session_sum(
                RegisterCashMovement.objects.filter(
                    register_session=OuterRef("pk"),
                    movement_type=RegisterCashMovement.MovementType.PAY_OUT,
                )
            ),
        )
        .annotate(
            cash_variance_amount=F("closing_cash")
            - (
                F("opening_cash")
                + F("variance_cash_sales")
                + F("variance_pay_in")
                - F("variance_pay_out")
                - F("variance_refunds")
            )
        )
        .exclude(cash_variance_amount=Decimal("0.00"))
    )
    for session in sessions:
        variance = session.cash_variance_amount
        if variance in (None, Decimal("0.00")):
            continue
        absolute_variance = abs(variance)
        specs.append(
            _spec(
                code="sales.register_variance",
                category=BusinessNotification.Category.SALES,
                severity=(
                    BusinessNotification.Severity.CRITICAL
                    if absolute_variance >= Decimal("100.00")
                    else BusinessNotification.Severity.WARNING
                ),
                fingerprint=f"sales.register_variance:{session.pk}",
                entity_type="sales.registersession",
                entity_id=str(session.pk),
                payload={
                    "session_number": session.session_number,
                    "amount": _money(absolute_variance),
                    "count": 1,
                },
            )
        )

    period_start = now - timedelta(days=30)
    orders = Order.objects.transactional().filter(
        created_at__gte=period_start,
        created_at__lt=now,
    )
    revenue_expr = SOLD_REVENUE_EXPRESSION
    cost_expr = SOLD_COST_EXPRESSION
    line_values = OrderLine.objects.filter(order__in=orders).aggregate(
        revenue=Coalesce(
            Sum(revenue_expr, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        cost=Coalesce(
            Sum(cost_expr, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
    )
    revenue = line_values["revenue"]
    cost = line_values["cost"]
    if revenue > 0 and cost > revenue:
        loss = cost - revenue
        specs.append(
            _spec(
                code="sales.negative_margin",
                category=BusinessNotification.Category.SALES,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint="sales.negative_margin:30d",
                entity_type="sales.order",
                entity_id="",
                payload={
                    "amount": _money(loss),
                    "percent": str(((loss / revenue) * Decimal("100")).quantize(Decimal("1"))),
                    "days": 30,
                    "count": orders.count(),
                },
            )
        )
    return specs


def _discount_notifications(now):
    specs = []
    rules = DiscountRule.objects.filter(
        is_active=True,
        ends_at__gte=now,
        ends_at__lte=now + timedelta(days=7),
    )
    for rule in rules:
        # Round the remaining time UP to whole days so an alert never reports
        # "0 days" for a rule that is still active, and the severity band lines
        # up with how a human reads it ("~36h left" is 2 days, not 1). Plain
        # ``timedelta.days`` truncates toward zero and produced an off-by-one.
        if rule.ends_at:
            remaining_seconds = int((rule.ends_at - now).total_seconds())
            days = max(0, -(-remaining_seconds // 86400))
        else:
            days = 0
        specs.append(
            _spec(
                code="discounts.expiring_rule",
                category=BusinessNotification.Category.DISCOUNTS,
                severity=(
                    BusinessNotification.Severity.WARNING
                    if days <= 2
                    else BusinessNotification.Severity.INFO
                ),
                fingerprint=f"discounts.expiring_rule:{rule.pk}",
                entity_type="discounts.discountrule",
                entity_id=str(rule.pk),
                payload={
                    "rule_name": rule.name,
                    "channel": rule.channel,
                    "ends_at": rule.ends_at.isoformat() if rule.ends_at else None,
                    "days": days,
                    "count": 1,
                },
            )
        )
    return specs


def _fraud_notifications(now):
    from apps.fraud.services import suspected_fraud_notification_specs

    return suspected_fraud_notification_specs(now=now)


def _payroll_notifications(now):
    from apps.employees.models import PayrollRun

    runs = (
        PayrollRun.objects.filter(status=PayrollRun.Status.DRAFT)
        .annotate(notification_line_count=Count("lines"))
        .filter(notification_line_count__gt=0)
        .order_by("-period_end", "-created_at")
    )
    specs = []
    for run in runs:
        specs.append(
            _spec(
                code="employees.payroll_ready",
                category=BusinessNotification.Category.OPERATIONS,
                severity=BusinessNotification.Severity.INFO,
                fingerprint=f"employees.payroll_ready:{run.pk}",
                entity_type="employees.payrollrun",
                entity_id=str(run.pk),
                payload={
                    "run_number": run.run_number,
                    "period_start": run.period_start.isoformat(),
                    "period_end": run.period_end.isoformat(),
                    "amount": _money(run.net_total),
                    "count": run.notification_line_count,
                },
            )
        )
    return specs


def _backup_notifications(now):
    """Escalate when the shop has no recent, verified way back.

    This is the alarm whose absence let a first client run 35 days on a wedged
    backup job and 18 straight failures without anyone noticing. It is
    deliberately a single notification rather than one per failed job: the
    question a manager needs answered is "can I restore?", not "which nights
    failed". It resolves itself the moment a verified backup lands, because
    sync_business_notifications retires managed codes whose fingerprint stops
    being generated.
    """
    health = backup_health(now)
    if not health["enabled"] or not health["is_stale"]:
        return []

    latest = health["latest_verified_at"]
    age = health["latest_verified_age"]
    return [
        _spec(
            code="operations.backup_unhealthy",
            category=BusinessNotification.Category.OPERATIONS,
            severity=BusinessNotification.Severity.CRITICAL,
            fingerprint="operations.backup_unhealthy",
            entity_type="core.systembackupschedule",
            entity_id="1",
            payload={
                "last_verified_at": latest.isoformat() if latest else None,
                "hours_since_verified": (
                    round(age.total_seconds() / 3600, 1) if age is not None else None
                ),
                "stale_after_hours": health["stale_after_hours"],
                "last_error": health["last_error"][:240],
                "last_attempt_at": (
                    health["last_attempt_at"].isoformat()
                    if health["last_attempt_at"]
                    else None
                ),
                "count": 1,
            },
        )
    ]


def _json_safe_payload(value):
    from decimal import Decimal

    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, dict):
        return {key: _json_safe_payload(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe_payload(item) for item in value]
    return value


def _upsert_notification(spec, now):
    """Create or refresh one notification; returns True when the upsert
    changed anything a client can see (new row, reactivation, or a field
    diff) — the ``last_seen_at``-only refresh of a persisting notification
    returns False so it never orphans feed ETags."""
    # Stock quantities are Decimals since weighted-product support; the
    # payload column is JSON, so coerce them at the boundary.
    if "payload" in spec:
        spec = {**spec, "payload": _json_safe_payload(spec["payload"])}
    # get_or_create keys on the unique fingerprint and absorbs the IntegrityError
    # from a concurrent insert (sync runs on a Celery beat AND, throttled, inline
    # on reads, so two syncs racing on the same fingerprint is possible). A plain
    # filter-then-create would raise under that race.
    defaults = {key: value for key, value in spec.items() if key != "fingerprint"}
    notification, created = BusinessNotification.objects.get_or_create(
        fingerprint=spec["fingerprint"],
        defaults={**defaults, "first_seen_at": now, "last_seen_at": now},
    )
    if created:
        return True

    was_resolved = notification.status == BusinessNotification.Status.RESOLVED
    materially_changed = was_resolved or any(
        getattr(notification, field) != spec[field]
        for field in ("code", "category", "severity", "entity_type", "entity_id", "payload")
    )
    notification.code = spec["code"]
    notification.category = spec["category"]
    notification.severity = spec["severity"]
    notification.status = BusinessNotification.Status.ACTIVE
    notification.entity_type = spec["entity_type"]
    notification.entity_id = spec["entity_id"]
    notification.payload = spec["payload"]
    notification.last_seen_at = now
    notification.resolved_at = None
    if was_resolved:
        notification.occurrence_count += 1
    notification.save(
        update_fields=[
            "code",
            "category",
            "severity",
            "status",
            "entity_type",
            "entity_id",
            "payload",
            "last_seen_at",
            "resolved_at",
            "occurrence_count",
            "updated_at",
        ]
    )
    if was_resolved:
        BusinessNotificationUserState.objects.filter(notification=notification).delete()
    return materially_changed


def _spec(
    *,
    code,
    category,
    severity,
    fingerprint,
    entity_type,
    entity_id,
    payload,
):
    return {
        "code": code,
        "category": category,
        "severity": severity,
        "fingerprint": fingerprint,
        "entity_type": entity_type,
        "entity_id": entity_id,
        "payload": payload,
    }


def _stock_payload(item):
    variant_name = item.variant.name.strip()
    product_name = item.variant.product.name
    display_name = f"{product_name} - {variant_name}" if variant_name else product_name
    return {
        "product_name": display_name,
        "sku": item.variant.sku,
        "quantity": float(item.quantity_on_hand),
        "threshold": item.reorder_level,
        "expected": item.quantity_expected,
        "count": 1,
    }


def _money(value):
    return str(Decimal(value).quantize(Decimal("0.01")))


def _codes_for_user(user):
    if not user or not user.is_authenticated:
        return ()
    manager = user_is_manager(user)
    return [
        code
        for code, rule in NOTIFICATION_AUDIENCE_RULES.items()
        if (manager or not rule["manager_only"])
        and any(user.has_perm(permission_code) for permission_code in rule["permissions"])
    ]


def _state_for_user(notification, user):
    for state in notification.user_states.all():
        if state.user_id == user.id:
            return state
    # When user_states is prefetched (the feed list always prefetches it), the
    # loop above is authoritative: the user simply has no state, so skip the
    # fallback query. Serializing each notification hits this four times (one
    # per state-derived field), so the fallback was a per-notification N+1 (x4)
    # across the whole feed on every read.
    if "user_states" in getattr(notification, "_prefetched_objects_cache", {}):
        return None
    return BusinessNotificationUserState.objects.filter(
        notification=notification,
        user=user,
    ).first()


def _integration_notifications(now):
    """What last night's provider reconciliation could not explain.

    Read from the rows themselves rather than from the sweep's return value,
    so the feed still tells the truth when a sweep is missed — and so a
    problem that has been fixed stops being reported without anyone clearing
    it, which is what the managed-code sweep does for every other builder.
    """
    from apps.integrations.models import IntegrationAccount, IntegrationFulfillment
    from apps.integrations.reconciliation import (
        DRIFT_TOLERANCE,
        UNPERFORMED_AFTER,
    )

    specs = []

    # 1. Sold and never performed. The customer is the one out of pocket.
    stale = (
        IntegrationFulfillment.objects.filter(
            status=IntegrationFulfillment.Status.PENDING,
            created_at__lte=now - UNPERFORMED_AFTER,
        )
        .select_related("order_line__order")
        .order_by("created_at")
    )
    for row in stale:
        specs.append(
            _spec(
                code="integrations.unperformed_recharge",
                category=BusinessNotification.Category.SALES,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint=f"integrations.unperformed_recharge:{row.pk}",
                entity_type="integrations.integrationfulfillment",
                entity_id=str(row.pk),
                payload={
                    "provider": row.provider,
                    "card_no": row.subscriber_ref,
                    "amount": _money(row.cost),
                    "sold_at": row.created_at.isoformat(),
                    "order_id": row.order_line.order_id,
                    "count": 1,
                },
            )
        )

    # 2. Sent, and we never learned what happened. Distinct from every other
    #    row here: this one is not "something went wrong" but "we do not know",
    #    and the only safe action is to look at the card. The guard in
    #    apps.integrations.recharge will not retry it, so nothing resolves it
    #    until reconciliation matches it against the provider's own log or a
    #    human settles it.
    unresolved = (
        IntegrationFulfillment.objects.filter(
            status=IntegrationFulfillment.Status.SUBMITTED,
        )
        .select_related("order_line__order")
        .order_by("submitted_at")
    )
    for row in unresolved:
        specs.append(
            _spec(
                code="integrations.unresolved_recharge",
                category=BusinessNotification.Category.SALES,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint=f"integrations.unresolved_recharge:{row.pk}",
                entity_type="integrations.integrationfulfillment",
                entity_id=str(row.pk),
                payload={
                    "provider": row.provider,
                    "card_no": row.subscriber_ref,
                    "amount": _money(row.cost),
                    "sent_at": row.submitted_at.isoformat() if row.submitted_at else "",
                    "order_id": row.order_line.order_id,
                    "reason": row.last_error_code,
                    "count": 1,
                },
            )
        )

    # 3 and 4 both read the same accounts, so they share one pass over them.
    from apps.integrations import float_ledger

    for account in IntegrationAccount.objects.filter(is_active=True):
        if account.balance is None:
            # Never probed, or probed and refused. Nothing below can say
            # anything honest about a float nobody has read.
            continue

        # 3. The float disagrees with our arithmetic. Catches money spent on
        #    cards Pointy has never seen, which no per-card check can.
        if account.money_account_id is not None:
            expected = float_ledger.expected_balance(account)
            drift = account.balance - expected
            if abs(drift) > DRIFT_TOLERANCE:
                specs.append(
                    _spec(
                        code="integrations.float_drift",
                        category=BusinessNotification.Category.SALES,
                        severity=BusinessNotification.Severity.WARNING,
                        fingerprint=f"integrations.float_drift:{account.pk}",
                        entity_type="integrations.integrationaccount",
                        entity_id=str(account.pk),
                        payload={
                            "provider": account.provider,
                            "amount": _money(abs(drift)),
                            # Which way it went changes what it means: less
                            # than expected is money spent outside Pointy,
                            # more is a top-up nobody wrote down.
                            "direction": "short" if drift < 0 else "over",
                            "expected": _money(expected),
                            "reported": _money(account.balance),
                            "count": 1,
                        },
                    )
                )

        # 4. The float is nearly out. Alone among these four it arrives
        #    *before* anything has gone wrong: the other three are reports on
        #    a sale that already failed, and this is the shop's chance to walk
        #    to the provider's office before one does. It needs no money
        #    account — a shop that has never recorded a top-up in Pointy still
        #    has a float, and is in fact the shop most likely to be surprised
        #    by it.
        specs.extend(_low_float_notification(account))
    return specs


def _low_float_notification(account):
    """The float warning for one account, against the owner's own threshold.

    Off by the owner's choice (``0``) is silence, including when the float is
    flat empty. An owner who turned the warning off and then got a critical
    alert would conclude the switch does not work, and would be right.

    The severity band is part of the fingerprint on purpose. "Getting low" and
    "cannot sell anything" are different facts, and somebody who dismissed the
    first must be told the second — an in-place severity bump would leave the
    row acknowledged and the bell silent at the worse moment.
    """
    from apps.integrations import catalog as provider_catalog

    if not account.is_configured:
        # The credentials are gone; the stored balance is a memory of a float
        # we can no longer read, and warning on it would be a guess.
        return []
    raw = account.setting(provider_catalog.SETTING_LOW_BALANCE_THRESHOLD)
    if raw is None:
        return []  # this provider declares no threshold
    threshold = Decimal(str(raw))
    if threshold <= 0 or account.balance > threshold:
        return []

    empty = account.balance <= 0
    return [
        _spec(
            code="integrations.low_float",
            category=BusinessNotification.Category.SALES,
            severity=(
                BusinessNotification.Severity.CRITICAL
                if empty
                else BusinessNotification.Severity.WARNING
            ),
            fingerprint=(
                f"integrations.low_float:{account.pk}:"
                f"{'empty' if empty else 'low'}"
            ),
            entity_type="integrations.integrationaccount",
            entity_id=str(account.pk),
            payload={
                "provider": account.provider,
                "account_label": account.account_label,
                "amount": _money(account.balance),
                "threshold": _money(threshold),
                # Every provider in the catalog settles in dinar, but the
                # figure is the provider's and the client renders it, so it
                # says which currency rather than leaving that to be assumed.
                "currency": account.spec.currency if account.spec else "LYD",
                # How old the number is. A float read at 02:20 and a float
                # read ten minutes ago support very different decisions, and
                # the reader is the one who should get to weigh that.
                "balance_at": (
                    account.balance_at.isoformat() if account.balance_at else ""
                ),
                "count": 1,
            },
        )
    ]
