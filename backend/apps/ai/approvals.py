"""Server-enforced approval for the assistant's money-moving and irreversible writes.

Until this existed, "confirm before you commit a sale" was a sentence in the system
prompt. A model that skipped it — or a prompt injection that told it to — could call
``create_sale(confirm=true)`` and the sale went through. The gate moves that rule out
of the prompt and into the agentic loop: when the model calls a gated action, the
loop does NOT run it. It pauses the turn and shows the user an approval card naming
the exact action and the figures it will commit. Only the user's tap on that card —
never the model, never tool output — runs the call, and it runs the arguments the
user saw, frozen at pause time, so nothing can change between approval and commit.

The categories follow the confirm-at-action-time tier: money in or out (sales,
payments, paid expenses, transfers, loans, payroll) and rules that silently change
every future price (discount rules).
"""

import json
from decimal import Decimal, InvalidOperation

APPROVAL_QUESTION_ID = "approve"

# The two-step commit tools: gated only on their committing call.
_CONFIRM_TOOLS = frozenset(
    {"create_sale", "record_customer_payment", "convert_quotation", "record_supplier_payment"}
)

# Generic writes gated by resource. An expense is gated only when it actually pays
# money out of a drawer or account; a recorded-only expense is bookkeeping.
_GATED_CREATE_RESOURCES = frozenset(
    {
        "money-transfers",
        "money-counts",
        "supplier-payments",
        "employee-loans",
        "payroll-runs",
        "discount-rules",
    }
)
_GATED_UPDATE_RESOURCES = frozenset({"discount-rules", "money-accounts", "expenses"})

# Arabic labels for the few fields worth showing on a card. Anything else is left
# off: the card is for a decision, not a field dump.
_FIELD_LABELS = {
    "name": "الاسم",
    "description": "الوصف",
    "amount": "المبلغ",
    "method": "طريقة الدفع",
    "payment_method": "طريقة الدفع",
    "amount_received": "المبلغ المستلَم",
    "value": "القيمة",
    "value_type": "نوع الخصم",
    "is_active": "مفعّلة",
    "reference": "المرجع",
    "notes": "ملاحظات",
    "note": "ملاحظة",
}

_METHOD_LABELS = {
    "cash": "نقدًا",
    "card": "بطاقة",
    "bank_transfer": "تحويل مصرفي",
    "transfer": "تحويل",
    "credit": "آجل",
}

_SALE_TYPE_LABELS = {"standard": "بيع عادي", "credit": "بيع آجل", "quotation": "عرض سعر"}


def _truthy(value):
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes"}
    return bool(value)


def _text(value):
    if isinstance(value, bool):
        return "نعم" if value else "لا"
    if isinstance(value, (int, float, Decimal)):
        return _number(value)
    text = str(value).strip()
    return _METHOD_LABELS.get(text, text)


def _number(value):
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return str(value)
    if number == number.to_integral_value():
        return f"{int(number):,}"
    return f"{number.normalize():,f}"


# A discount rule's "value" may be a percentage, so it stays plain text.
_MONEY_FIELDS = frozenset({"amount", "amount_received"})


def _detail(label, value, *, money=False):
    """One card row. Money rows carry the raw number and ``kind: money`` so the
    app formats them with its own currency rules, never a server-side string."""
    if value in (None, "", [], {}):
        return None
    if money:
        try:
            return {"label": label, "value": str(Decimal(str(value))), "kind": "money"}
        except (InvalidOperation, ValueError):
            pass
    return {"label": label, "value": _text(value)}


def _field_details(data):
    details = []
    if isinstance(data, dict):
        for key, label in _FIELD_LABELS.items():
            row = _detail(label, data.get(key), money=key in _MONEY_FIELDS)
            if row is not None:
                details.append(row)
    return details[:6]


def _resource_name(resource):
    from .tool_registry import get_registry

    meta = get_registry().get(resource)
    return meta.description if meta is not None else resource


def _sale_details(args, user):
    """Lines, customer and the server-computed total. The total comes from the same
    discount preview the checkout will run, so the user approves the real figure,
    not one the model typed."""
    from .tools import create_sale

    lines = args.get("lines") if isinstance(args.get("lines"), list) else []
    details = [{"label": "عدد البنود", "value": _number(len(lines))}]
    preview = create_sale(
        user=user,
        lines=lines,
        customer=args.get("customer"),
        coupon_codes=args.get("coupon_codes"),
        confirm=False,
    )
    data = (preview.get("preview") or {}) if preview.get("ok") else {}
    for key, label in (("subtotal", "المجموع"), ("discount_total", "الخصم"), ("total", "الإجمالي")):
        row = _detail(label, data.get(key), money=True)
        if row is not None:
            details.append(row)
    for key, label, mapping in (
        ("sale_type", "نوع البيع", _SALE_TYPE_LABELS),
        ("payment_method", "طريقة الدفع", _METHOD_LABELS),
    ):
        raw = args.get(key)
        if raw:
            details.append({"label": label, "value": mapping.get(str(raw), str(raw))})
    row = _detail("المبلغ المستلَم", args.get("amount_received"), money=True)
    if row is not None:
        details.append(row)
    row = _detail("العميل", args.get("customer"))
    if row is not None:
        row["value"] = f"#{row['value']}"
        details.append(row)
    return details


def _describe(name, args, user):
    """``(title, details)`` for a gated call, or None when the call needs no approval."""
    if name in _CONFIRM_TOOLS:
        if not _truthy(args.get("confirm")):
            return None  # the preview step is read-only
        if name == "create_sale":
            return "تأكيد إتمام البيع", _sale_details(args, user)
        if name == "record_customer_payment":
            return "تأكيد تسجيل دفعة عميل", [
                row
                for row in (
                    _detail("الفاتورة", f"#{args.get('order_id')}" if args.get("order_id") else None),
                    _detail("المبلغ", args.get("amount"), money=True),
                    _detail("طريقة الدفع", args.get("method")),
                )
                if row
            ]
        if name == "convert_quotation":
            return "تأكيد تحويل عرض السعر إلى بيع", [
                row
                for row in (
                    _detail("عرض السعر", f"#{args.get('quotation_id')}" if args.get("quotation_id") else None),
                    _detail("نوع البيع", _SALE_TYPE_LABELS.get(str(args.get("sale_type")), args.get("sale_type"))),
                    _detail("المبلغ المستلَم", args.get("amount_received"), money=True),
                )
                if row
            ]
        return "تأكيد دفعة للمورّد", [
            row
            for row in (
                _detail("المورّد", f"#{args.get('supplier_id')}" if args.get("supplier_id") else None),
                _detail("المبلغ", args.get("amount"), money=True),
                _detail("طريقة الدفع", args.get("method")),
                _detail("أمر الشراء", f"#{args.get('purchase_order_id')}" if args.get("purchase_order_id") else None),
            )
            if row
        ]

    resource = args.get("resource")
    data = args.get("data") if isinstance(args.get("data"), dict) else {}
    if name == "create_resource":
        pays_out = resource == "expenses" and (
            _truthy(data.get("pay_from_register")) or data.get("money_account") not in (None, "")
        )
        if resource not in _GATED_CREATE_RESOURCES and not pays_out:
            return None
        details = _field_details(data)
        if pays_out:
            details.append(
                {"label": "يُدفع من", "value": "الصندوق" if _truthy(data.get("pay_from_register")) else "حساب مالي"}
            )
        return f"تأكيد إنشاء: {_resource_name(resource)}", details
    if name == "update_resource":
        if resource not in _GATED_UPDATE_RESOURCES:
            return None
        details = [{"label": "السجل", "value": f"#{args.get('id')}"}] + _field_details(data)
        return f"تأكيد تعديل: {_resource_name(resource)}", details
    return None


def approval_request(name, args, *, user):
    """The approval spec for a gated tool call, or None if it may run directly.

    The spec is an ordinary ``ask_user`` question (a ``confirm``) so it rides the
    existing pause/resume path and card, plus an ``approval`` block holding the
    frozen call that the resume endpoint — not the model — will execute."""
    described = _describe(name, args if isinstance(args, dict) else {}, user)
    if described is None:
        return None
    title, details = described
    return {
        "questions": [
            {
                "id": APPROVAL_QUESTION_ID,
                "type": "confirm",
                "prompt": title,
                "help": "لن يُنفَّذ شيء قبل موافقتك.",
                "required": True,
                "config": {
                    "approval": True,
                    "details": details,
                    "confirm_label": "موافقة وتنفيذ",
                    "deny_label": "إلغاء",
                },
            }
        ],
        "approval": {"name": name, "arguments": args},
    }


def approval_granted(answers, declined):
    """Whether the user's resume answer approves the paused call. Anything other
    than an explicit yes on the approval question — a skip, a "no", a malformed
    answer — is a refusal."""
    if declined:
        return False
    for answer in answers or []:
        if isinstance(answer, dict) and answer.get("question_id") == APPROVAL_QUESTION_ID:
            return answer.get("value") is True
    return False


def not_run_reply(call):
    """The tool reply recorded for a sibling call that was queued behind a gated
    one in the same batch: it never ran, and the model must re-issue it if it still
    needs it once the user has answered."""
    return {
        "role": "tool",
        "tool_call_id": call.get("id", ""),
        "name": (call.get("function") or {}).get("name", ""),
        "content": json.dumps(
            {
                "ok": False,
                "error": "not_run",
                "message": "لم تُنفَّذ: كانت بانتظار موافقة المستخدم على عملية قبلها. أعد استدعاءها إن لزم.",
            },
            ensure_ascii=False,
        ),
    }
