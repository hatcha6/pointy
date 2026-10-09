"""The at-most-once guard around a provider write.

The providers Pointy resells are not idempotent and cannot be made so from the
outside: HD Box's renew form carries a per-view token, but whether the server
spends it could not be established, because its funds check answers first and
hides the token check. So Pointy does not get to rely on the provider refusing
a duplicate. It has to not send one.

That turns one rule into the whole design: **a charge is attempted at most
once, and an attempt whose outcome is unknown is never attempted again.**

Three phases, and the boundaries between them are the point:

1. **Claim** — in its own committed transaction, move the fulfillment from
   ``pending`` to ``submitted`` under ``SELECT FOR UPDATE``. After this commit,
   the database says an attempt exists, whatever happens to this process next.
2. **Call** — outside any transaction, because a request that is rolled back
   still spent the money. The claim must already be durable when the packet
   leaves.
3. **Record** — in a second transaction, write what came back.

A process that dies between 2 and 3 leaves the row in ``submitted``, which
reads as "we sent something and do not know what happened". That is the honest
state, and :mod:`apps.integrations.reconciliation` resolves it against the
provider's own purchase log — the only authority on whether money moved. A
provider that is idempotent on a key of ours (the company's relay) is told the
attempt's key (:func:`attempt_key`), and the attempt is settled by reading it
back under that key instead.

Nothing here ever retries. A caller that wants another go must first get the
row back to ``pending``, which only reconciliation does, and only once it has
proved the provider never performed it.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal

from django.db import transaction
from django.utils import timezone

from apps.core.state_version import bump

from . import services_options, switches
from .fulfillment import fulfillment_kind, sale_withdrawn
from .models import IntegrationFulfillment
from .providers import provider_for
from .providers.base import ERROR_INDETERMINATE, ERROR_SWITCHED_OFF, RechargeResult

# --- outcomes ---------------------------------------------------------------
#: The provider confirmed it. Money left the float, time landed on the card.
OUTCOME_CHARGED = "charged"
#: The provider refused, definitely, and the float is untouched.
OUTCOME_REFUSED = "refused"
#: We do not know. Money may have moved. Do not retry; reconcile.
OUTCOME_UNKNOWN = "unknown"
#: Nothing was sent, because this row was not in a state that may be charged.
OUTCOME_NOT_CLAIMABLE = "not_claimable"

_CENT = Decimal("0.01")

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ChargeOutcome:
    outcome: str
    fulfillment: IntegrationFulfillment | None = None
    error_code: str = ""
    error_detail: str = ""
    balance_after: Decimal | None = None

    @property
    def ok(self) -> bool:
        return self.outcome == OUTCOME_CHARGED

    @property
    def needs_attention(self) -> bool:
        """True when a human has to go and look before anything else happens."""
        return self.outcome == OUTCOME_UNKNOWN


class AtomicBlockError(RuntimeError):
    """Raised when a caller tries to charge from inside a transaction.

    The guard is only worth anything if the claim is committed before the
    provider is called. Inside an outer ``atomic()`` it would not be: the claim
    would still be invisible to everyone else, and a rollback would erase the
    record of an attempt that really did spend money. This is a programming
    error, so it is loud rather than silent.
    """


def charge(fulfillment_id: int, *, user=None) -> ChargeOutcome:
    """Perform the recharge for one fulfillment, at most once, ever."""
    if transaction.get_connection().in_atomic_block:
        raise AtomicBlockError(
            "integrations.recharge.charge() must not run inside a transaction: "
            "the claim has to be committed before the provider is called."
        )

    # A provider the operator switched off is not even claimed for: nothing
    # will be sent, so the line stays merely sold — neither an attempt nor a
    # refusal on its record — for a refund, or for when it is back on.
    off = switches.switched_off_providers()
    if off:
        current = IntegrationFulfillment.objects.filter(pk=fulfillment_id).first()
        if current is not None and current.provider in off:
            return ChargeOutcome(
                outcome=OUTCOME_REFUSED,
                fulfillment=current,
                error_code=ERROR_SWITCHED_OFF,
            )

    claimed = _claim(fulfillment_id)
    if claimed is None:
        current = IntegrationFulfillment.objects.filter(pk=fulfillment_id).first()
        return ChargeOutcome(
            outcome=OUTCOME_NOT_CLAIMABLE,
            fulfillment=current,
            error_code="not_claimable",
            error_detail=("" if current is None else f"status is {current.status}"),
        )

    # --- past this line a charge may have happened, whatever we observe ---
    # Never None: an unregistered provider gets the planned-provider stub,
    # whose recharge() is a definite "not available" rather than a surprise.
    driver = provider_for(claimed.account)
    driver.bind(claimed)
    try:
        result = driver.recharge(
            claimed.subscriber_ref,
            claimed.option_code,
            expected_cost=cost_ceiling(claimed),
            attempt_key=attempt_key(claimed),
        )
    except Exception as exc:  # noqa: BLE001 — a driver bug is not proof of a refund
        # A driver is contracted never to raise, but if one does we still do
        # not know whether the request left the machine. Unknown, not failed.
        result = RechargeResult(
            ok=False,
            indeterminate=True,
            error_code=ERROR_INDETERMINATE,
            error_detail=f"{type(exc).__name__}: {exc}",
        )
    return _record(claimed, result)


def attempt_key(fulfillment) -> str:
    """The name of this row's current attempt, for a provider idempotent on one.

    Stable for as long as the attempt is unsettled — the relay answers a replay
    of it with the first purchase, and reconciliation reads the purchase back
    by it — and different for every attempt the row is allowed: the attempt
    count moves only once an earlier attempt was proved never performed.

    The row's creation instant is in it so that a key can never name another
    shop-life's purchase: primary keys start again after a factory reset or a
    restored backup, and a bare ``42-1`` would then be answered with the codes
    of a card some earlier sale bought.
    """
    return f"{fulfillment.pk}-{fulfillment.created_at:%Y%m%d%H%M%S%f}-{fulfillment.attempt_count}"


def cost_ceiling(row) -> Decimal:
    """The most the provider may charge the shop for ``row``: the driver's ``expected_cost``.

    For a card or an ordinary recharge it is the cost the sale was rung up at:
    a provider whose price has moved up since is refused, so the shop never
    pays more than it sold against.

    The company's direct top-ups and bill payments are held to **what the
    customer actually paid for the line** instead — its total after every
    discount, the cashier's and the rules' alike. The relay's price follows the
    exchange rate (its directory is refreshed every few minutes), a quote never
    expires and a held invoice may be hours old, so refusing every upward move
    strands a customer who has already paid with nothing delivered. The relay
    charges its *current* price whenever that is within the ceiling — what it
    really charged is recorded (:func:`apply_actual_cost`) — and refuses
    ``price_changed`` only once the cost has passed what the sale brought in:
    the point from which performing it loses the shop money on this line. Never
    below the cost the sale was rung up at (a line given away is still bought at
    its cost, not refused for being free).

    Read off the sold line (``line_total``): one line, one order, in its base
    unit, so it is the whole of what was paid. Never raises; with the line
    unreadable the ceiling is the stricter one, the cost.
    """
    cost = Decimal(row.cost)
    try:
        if fulfillment_kind(row) not in services_options.KINDS:
            return cost
        return max(cost, Decimal(row.order_line.line_total))
    except Exception:  # noqa: BLE001 - see the docstring
        logger.warning(
            "could not read the price of fulfillment %s", row.pk, exc_info=True
        )
        return cost


def apply_actual_cost(row, actual_cost) -> list[str]:
    """Make a fulfillment, and the line that sold it, cost what was really paid.

    The relay charges its current price when that is not higher than the cost
    the sale was rung up at (a promotion started since the shelf was read), so
    the float drew less than the line says. The line's ``unit_cost`` is what
    the profit report reads, and the fulfillment's ``cost`` what the float
    ledger draws — both must say what was actually spent. Returns the row's
    fields it changed; the caller saves them, inside its own transaction.
    """
    if actual_cost is None:
        return []
    cost = Decimal(actual_cost).quantize(_CENT, rounding=ROUND_HALF_UP)
    if cost == Decimal(row.cost).quantize(_CENT, rounding=ROUND_HALF_UP):
        return []
    row.cost = cost
    line = row.order_line
    # A card is sold one to a line, in its base unit: the line's unit cost IS
    # the card's cost (see ``sales.services.create_order_with_lines``).
    line.unit_cost = (cost * (line.unit_factor or Decimal("1"))).quantize(
        _CENT, rounding=ROUND_HALF_UP
    )
    line.save(update_fields=["unit_cost", "updated_at"])
    return ["cost"]


def _claim(fulfillment_id: int) -> IntegrationFulfillment | None:
    """Take exclusive ownership of the one attempt this row is allowed.

    Not for a sale that has been given back. A void and a return take the
    sale's lock first and withdraw what is still pending (:func:`.fulfillment.
    cancel_unperformed`); taking the same lock first here is what makes a charge
    and a void of one sale queue behind each other instead of both winning. A
    row a void left pending before that existed is retired when it is met.
    """
    from apps.sales.models import Order

    with transaction.atomic():
        order_id = (
            IntegrationFulfillment.objects.filter(pk=fulfillment_id)
            .values_list("order_line__order_id", flat=True)
            .first()
        )
        if order_id is not None:
            list(
                Order.objects.select_for_update()
                .filter(pk=order_id)
                .values_list("pk", flat=True)
            )
        row = (
            IntegrationFulfillment.objects.select_for_update()
            .filter(pk=fulfillment_id, status=IntegrationFulfillment.Status.PENDING)
            .select_related("account")
            .first()
        )
        if row is None:
            return None
        if sale_withdrawn(row.order_line_id):
            row.status = IntegrationFulfillment.Status.CANCELLED
            row.save(update_fields=["status", "updated_at"])
            bump("integrations")
            return None
        row.status = IntegrationFulfillment.Status.SUBMITTED
        row.submitted_at = timezone.now()
        row.attempt_count += 1
        row.last_error_code = ""
        row.last_error = ""
        row.save(
            update_fields=[
                "status",
                "submitted_at",
                "attempt_count",
                "last_error_code",
                "last_error",
                "updated_at",
            ]
        )
        return row


def _record(fulfillment, result: RechargeResult) -> ChargeOutcome:
    """Write down what came back, and nothing more than what came back."""
    with transaction.atomic():
        row = (
            IntegrationFulfillment.objects.select_for_update()
            .select_related("account", "order_line")
            .get(pk=fulfillment.pk)
        )
        fields = ["status", "last_error_code", "last_error", "updated_at"]

        if result.ok:
            row.status = IntegrationFulfillment.Status.CONFIRMED
            row.confirmed_at = timezone.now()
            row.provider_reference = result.reference or ""
            row.provider_receipt = result.receipt or {}
            row.last_error_code = ""
            row.last_error = ""
            fields += ["confirmed_at", "provider_reference", "provider_receipt"]
            fields += apply_actual_cost(row, result.actual_cost)
            outcome = OUTCOME_CHARGED
        elif result.indeterminate:
            # Stays SUBMITTED on purpose. This is the state that stops a
            # second charge, and only reconciliation may move it.
            row.status = IntegrationFulfillment.Status.SUBMITTED
            row.last_error_code = result.error_code or ERROR_INDETERMINATE
            row.last_error = result.error_detail or ""
            outcome = OUTCOME_UNKNOWN
        else:
            # A definite refusal: the provider never took the money, so this
            # row goes back to being merely sold, and may be tried again.
            row.status = IntegrationFulfillment.Status.PENDING
            row.last_error_code = result.error_code or ""
            row.last_error = result.error_detail or ""
            outcome = OUTCOME_REFUSED
        row.save(update_fields=fields)

        account = row.account
        if result.balance_after is not None:
            # The write tells us the new float, so no extra probe is needed.
            account.balance = result.balance_after
            account.balance_at = timezone.now()
            account.save(update_fields=["balance", "balance_at", "updated_at"])

        # bump() defers to on_commit itself, so this lands when the row does.
        bump("integrations")

    return ChargeOutcome(
        outcome=outcome,
        fulfillment=row,
        error_code=row.last_error_code,
        error_detail=row.last_error,
        balance_after=result.balance_after,
    )
