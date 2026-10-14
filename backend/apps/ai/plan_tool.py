"""``update_plan`` — the step checklist the assistant keeps for a multi-step task.

Codex's agent posts a plan and ticks it off as it works; the user watches the
task move instead of staring at a spinner while ten tools run. Pointy's version
is the same idea: the model sends the whole list each time (a few short Arabic
steps with a status), the loop streams it as a ``plan`` event and keeps the
latest on the assistant turn. It runs nothing and touches no shop data.
"""

PLAN_TOOL_NAME = "update_plan"

PLAN_STATUSES = ("pending", "in_progress", "completed")

_MAX_STEPS = 8
_MAX_STEP_CHARS = 120


def validate_plan(arguments):
    """The sanitised step list, or None when there is nothing usable.

    Never raises: the model's JSON can be partial. Unknown statuses fall back
    to ``pending``, and at most one step may be in progress — the first one the
    model marked — so the checklist always reads as a single current step."""
    raw = arguments.get("steps") if isinstance(arguments, dict) else None
    if not isinstance(raw, list):
        return None
    steps = []
    in_progress_seen = False
    for item in raw:
        if not isinstance(item, dict):
            continue
        text = str(item.get("step") or "").strip()[:_MAX_STEP_CHARS]
        if not text:
            continue
        status = item.get("status")
        if status not in PLAN_STATUSES:
            status = "pending"
        if status == "in_progress":
            if in_progress_seen:
                status = "pending"
            in_progress_seen = True
        steps.append({"step": text, "status": status})
        if len(steps) >= _MAX_STEPS:
            break
    return steps or None


def plan_tool_definition():
    return {
        "type": "function",
        "function": {
            "name": PLAN_TOOL_NAME,
            "description": (
                "اعرض للمستخدم خطة مهمة متعددة الخطوات وحدّثها أثناء التنفيذ. استخدمها "
                "فقط للمهام ذات ثلاث خطوات فعلية فأكثر (مثل إنشاء طبق بوصفته ومكوّناته، أو "
                "إعادة طلب تنتج عدّة أوامر شراء)، ولا تستخدمها للأسئلة العادية. أرسل القائمة "
                "كاملة في كل مرة: خطوات قصيرة بالعربية، وخطوة واحدة فقط in_progress، وعلّم "
                "الخطوة completed فور إنجازها. حدّث الخطة في نفس الدور مع الأداة التالية، "
                "ولا تكتب الخطة نصًا في ردّك."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "steps": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": _MAX_STEPS,
                        "items": {
                            "type": "object",
                            "properties": {
                                "step": {"type": "string", "description": "الخطوة، بإيجاز."},
                                "status": {"type": "string", "enum": list(PLAN_STATUSES)},
                            },
                            "required": ["step", "status"],
                            "additionalProperties": False,
                        },
                    }
                },
                "required": ["steps"],
                "additionalProperties": False,
            },
        },
    }
