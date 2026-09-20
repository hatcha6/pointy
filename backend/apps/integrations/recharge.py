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
provider's own purchase log — the only authority on whether money moved.

Nothing here ever retries. A caller that wants another go must first get the
row back to ``pending``, which only reconciliation does, and only once it has
proved the provider never performed it.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from apps.core.state_version import bump

from .models import IntegrationFulfillment
from .providers import provider_for
from .providers.base import ERROR_INDETERMINATE, RechargeResult

# --- outcomes ---------------------------------------------------------------
#: The provider confirmed it. Money left the float, time landed on the card.
OUTCOME_CHARGED = "charged"
#: The provider refused, definitely, and the float is untouched.
OUTCOME_REFUSED = "refused"
#: We do not know. Money may have moved. Do not retry; reconcile.
OUTCOME_UNKNOWN = "unknown"
#: Nothing was sent, because this row was not in a state that may be charged.
OUTCOME_NOT_CLAIMABLE = "not_claimable"


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

    claimed = _claim(fulfillment_id)
    if claimed is None:
        current = IntegrationFulfillment.objects.filter(pk=fulfillment_id).first()
        return ChargeOutcome(
            outcome=OUTCOME_NOT_CLAIMABLE,
            fulfillment=current,
            error_code="not_claimable",
            error_detail=(
                "" if current is None else f"status is {current.status}"
            ),
        )

    # --- past this line a charge may have happened, whatever we observe ---
    # Never None: an unregistered provider gets the planned-provider stub,
    # whose recharge() is a definite "not available" rather than a surprise.
    driver = provider_for(claimed.account)
    try:
        result = driver.recharge(
            claimed.subscriber_ref,
            claimed.option_code,
            expected_cost=claimed.cost,
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


def _claim(fulfillment_id: int) -> IntegrationFulfillment | None:
    """Take exclusive ownership of the one attempt this row is allowed."""
    with transaction.atomic():
        row = (
            IntegrationFulfillment.objects.select_for_update()
            .filter(pk=fulfillment_id, status=IntegrationFulfillment.Status.PENDING)
            .select_related("account")
            .first()
        )
        if row is None:
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
            .select_related("account")
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
