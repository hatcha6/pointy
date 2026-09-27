"""Who is told what a sale below cost would lose.

``prevent_selling_at_loss`` refuses such a sale, and the till warns about one
before it gets that far. Both name the offending lines, and both used to price
them — ``unit_cost``, ``line_cost`` and ``loss_amount`` — to anyone who could
ring up a sale. The loss is the cost less a line total the cashier typed, so it
is the cost by another name. The discount preview answers on every cart edit,
and a manual discount has no ceiling unless the shop set one, so a cashier could
put one item in the cart, discount it to nothing and read what the owner paid
for it. For an identified article the figure is that article's own cost, which
the stock-unit cost mask exists to keep from them.

So a loss line is named to everyone and priced only for the people who may see
cost anyway: the reporting roles, who read margins on every order, and anyone
granted ``sales.view_till_cost``. The guard itself is untouched. It decides on
the full figures, server-side; only what leaves the server changes.
"""

from rest_framework.views import exception_handler as drf_exception_handler

from apps.core.roles import user_has_full_visibility

#: The code a sale refused below cost carries (``sale_loss_blocked_payload``).
SALE_AT_LOSS_BLOCKED = "sale_at_loss_blocked"

TILL_COST_PERMISSION = "sales.view_till_cost"

#: What a loss line keeps for a reader who may not see cost: which line, and the
#: figures they rang up themselves. An allow-list rather than the three cost
#: names, so a figure added to the payload later reaches a cashier only when
#: someone decides it should. Removed rather than blanked, like the order
#: margins: a zero cost and a hidden one read the same to a client, and only
#: one of them is true.
LOSS_LINE_FIELDS_WITHOUT_COST = (
    "line_key",
    "product",
    "product_id",
    "variant",
    "variant_id",
    "product_name",
    "variant_name",
    "quantity",
    "unit_price",
    "discount_total",
    "line_total",
)


def reader_sees_till_cost(context):
    """Whether the request behind ``context`` may see what a line cost the
    shop: the reporting roles (``reader_sees_margins``), plus anyone granted
    the till-cost permission. Asked once per response and kept in ``context`` —
    a serializer's, or the exception handler's — because the question costs
    queries."""
    if "_reader_sees_till_cost" not in context:
        user = getattr(context.get("request"), "user", None)
        context["_reader_sees_till_cost"] = user_has_full_visibility(user) or (
            user is not None and user.has_perm(TILL_COST_PERMISSION)
        )
    return context["_reader_sees_till_cost"]


def loss_lines_for_reader(loss_lines, context):
    """``loss_lines`` as the reader behind ``context`` may have them. A cart
    with no loss asks nothing — the preview runs on every keystroke."""
    if not loss_lines or reader_sees_till_cost(context):
        return loss_lines
    return [
        {
            field: line[field]
            for field in LOSS_LINE_FIELDS_WITHOUT_COST
            if field in line
        }
        for line in loss_lines
    ]


def exception_handler(exc, context):
    """DRF's handler, plus one thing it cannot know: a sale refused below cost
    is priced only for a reader who may see cost.

    Here rather than at the ``raise`` because the refusal comes from deep in the
    sale services — checkout, a quotation's conversion, an exchange, the payment
    that settles an invoice, a repair job's invoice, a website top-up — none of
    which know who is reading, and a path added later is covered without anyone
    remembering this exists.

    Decided before DRF's handler runs: under ``ATOMIC_REQUESTS`` it marks the
    request's transaction for rollback, after which the permission lookup could
    no longer query.
    """
    detail = getattr(exc, "detail", None)
    redact = _is_sale_at_loss_refusal(detail) and not reader_sees_till_cost(
        context
    )
    response = drf_exception_handler(exc, context)
    if redact and response is not None:
        response.data = {
            **detail,
            "loss": loss_lines_for_reader(detail["loss"], context),
        }
    return response


def _is_sale_at_loss_refusal(detail):
    if not isinstance(detail, dict) or not isinstance(detail.get("loss"), list):
        return False
    code = detail.get("code")
    # Raised inside a serializer's ``validate``, DRF wraps each value in a list.
    if isinstance(code, list) and len(code) == 1:
        code = code[0]
    return code == SALE_AT_LOSS_BLOCKED
