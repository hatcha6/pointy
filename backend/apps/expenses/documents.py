"""What an expense means to the document lifecycle.

An expense used to be deletable. That is the honest thing to compare a
cancellation against: deleting one made it stop counting everywhere, instantly
and silently, and left a drawer pay-out behind with nothing to explain it.
Cancelling makes it stop counting the same way — every sum reads ``.live()`` —
puts the cash back in the till it left, and says who did it and why.
"""

from apps.expenses.models import Expense


def in_place_allowed(expense) -> bool:
    """Whether the expense can still be rewritten.

    The same rule the drawer has always imposed: once the register session that
    paid it has been counted and closed, the till was reconciled against this
    pay-out and signed off. Rewriting the amount afterwards would rewrite that
    count.
    """
    from apps.expenses.services import drawer_fields_locked

    return not drawer_fields_locked(expense)


def reverse(expense, *, at, actor, reason="", context=None):
    """Put the money back where it came from.

    Only cash has somewhere to go back to. A card or transfer expense simply
    stops counting — which is exactly what deleting it used to do, minus the
    silence.
    """
    from apps.sales.models import RegisterCashMovement

    context = context or {}
    if expense.cash_movement_id is None:
        return None
    session = context.get("register_session") or expense.register_session
    return RegisterCashMovement.objects.create(
        register_session=session,
        movement_type=RegisterCashMovement.MovementType.PAY_IN,
        amount=expense.amount,
        reason=f"إلغاء مصروف: {expense.category.name} — {expense.description}",
        created_by=actor,
    )


__all__ = ["Expense", "in_place_allowed", "reverse"]
