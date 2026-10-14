"""The assistant's opening suggestions, written by the assistant for this shop.

The empty chat used to offer the same three generic prompts to every shop
("write a welcome message…"). These are generated instead from what the
assistant actually knows: this user's dashboard figures (built through the same
capability-gated snapshot as the dashboard, so a cashier's suggestions never
lean on profit they cannot see), its memories about the shop and this user,
the day and the hour. The aim is a question the owner did not know to ask —
"why did coffee drop on Tuesday?" — rather than a feature tour.

One relay call, never persisted, never metered (``count_usage=False``), cached
per user for a few hours by the view. Any failure returns ``None`` and the app
keeps its built-in suggestions.
"""

from __future__ import annotations

import json
import logging

from django.utils import timezone

from apps.core.models import ShopSettings
from apps.core.relay import RelayControlError

from .relay_stream import _shop_context_sentence, iter_relay_sse

logger = logging.getLogger(__name__)

SUGGESTION_ICONS = ("sales", "stock", "customers", "purchasing", "marketing", "money", "report", "idea")

_COUNT = 4
_MAX_TITLE_CHARS = 70
_MAX_PROMPT_CHARS = 300
_MAX_TOKENS = 600
_MEMORY_LINES = 20

_WEEKDAYS = ("الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت", "الأحد")


def _day_part(hour):
    if hour < 11:
        return "بداية اليوم"
    if hour < 17:
        return "منتصف اليوم"
    return "نهاية اليوم"


def _memory_lines(user):
    from .memory import visible_memories

    return [m.content for m in visible_memories(user)[:_MEMORY_LINES]]


def _messages(figures, memories, shop, *, sees_margins):
    now = timezone.localtime()
    example = json.dumps(
        {
            "suggestions": [
                {
                    "title": "لماذا تراجعت مبيعات القهوة يوم الثلاثاء؟",
                    "prompt": "مبيعات القهوة التركي تراجعت يوم الثلاثاء الماضي. حلّل السبب وقارنها بالأسابيع السابقة.",
                    "icon": "sales",
                }
            ]
        },
        ensure_ascii=False,
    )
    margin_rule = (
        ""
        if sees_margins
        else "هذا المستخدم لا يرى التكاليف والأرباح: لا تقترح شيئًا عن الربح أو الهامش أو التكلفة. "
    )
    system = (
        "أنت GPT، مساعد متجر ذكي. " + _shop_context_sentence(shop)
        + f"اكتب {_COUNT} اقتراحات افتتاحية تظهر للمستخدم في شاشة محادثة فارغة، "
        "ليضغط أحدها فيُرسَل إليك. المطلوب اقتراحات تثير فضوله لأنها عن متجره هو: "
        "اذكر أسماء أصناف أو موردين أو أرقامًا حقيقية من البيانات أو من الذاكرة، "
        "واكشف شيئًا لم ينتبه له (تغيّر لافت، صنف على وشك النفاد، فرصة بيع، عميل "
        "متأخر، روتين معتاد في هذا الوقت). نوّع: سؤال تحليلي عن تغيّر لافت، وإجراء "
        "عملي (إعادة طلب، عرض، تحصيل)، وفكرة نمو أو تسويق، وواحد يناسب الوقت الحالي "
        "أو روتينًا من الذاكرة. لا اقتراحات عامة تصلح لأي متجر، ولا تخترع أرقامًا أو "
        "أسماء غير موجودة في المعطيات. " + margin_rule
        + "title سطر قصير بصوت المستخدم يُعرض على الزر (حتى "
        f"{_MAX_TITLE_CHARS} حرفًا)، وprompt الطلب الكامل الذي يُرسَل لك بصوت المستخدم "
        f"وبتفاصيله (حتى {_MAX_PROMPT_CHARS} حرفًا)، وicon واحدة من: "
        + "، ".join(SUGGESTION_ICONS) + ". "
        "أعد JSON صالحًا فقط بلا أي نص آخر ولا أسوار شيفرة. مثال الشكل: " + example
    )
    context = {
        "now": {"weekday": _WEEKDAYS[now.weekday()], "part_of_day": _day_part(now.hour)},
        "figures": figures,
        "memories": memories,
    }
    user = "هذا ما تعرفه الآن عن المتجر. اكتب الاقتراحات بالعربية:\n" + json.dumps(
        context, ensure_ascii=False
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def parse_suggestions(text):
    """The sanitised suggestion list from the model's reply, or None."""
    if not text:
        return None
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        raw = json.loads(text[start : end + 1])
    except (json.JSONDecodeError, ValueError):
        return None
    items = raw.get("suggestions") if isinstance(raw, dict) else None
    if not isinstance(items, list):
        return None
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or "").strip()[:_MAX_TITLE_CHARS]
        prompt = str(item.get("prompt") or "").strip()[:_MAX_PROMPT_CHARS] or title
        if not title:
            continue
        icon = item.get("icon") if item.get("icon") in SUGGESTION_ICONS else "idea"
        out.append({"title": title, "prompt": prompt, "icon": icon})
        if len(out) >= _COUNT:
            break
    # Fewer than two is not worth replacing the built-in set for.
    return out if len(out) >= 2 else None


def generate_suggestions(*, client, installation, user, figures):
    """``[{title, prompt, icon}]`` for this user, or None on any failure."""
    from .tools import _sees_margins

    memories = _memory_lines(user)
    if not figures and not memories:
        return None
    messages = _messages(figures, memories, ShopSettings.load(), sees_margins=_sees_margins(user))
    try:
        response = client.open_ai_stream(
            access_token=installation.access_token,
            messages=messages,
            count_usage=False,
            max_tokens=_MAX_TOKENS,
            temperature=0.8,
        )
    except RelayControlError:
        logger.warning("AI suggestions: relay call failed", exc_info=True)
        return None
    chunks = []
    try:
        for event in iter_relay_sse(response):
            if event.get("event") == "delta":
                chunks.append((event.get("data") or {}).get("text", ""))
    except Exception:
        logger.warning("AI suggestions: stream read failed", exc_info=True)
        return None
    finally:
        close = getattr(response, "close", None)
        if callable(close):
            close()
    raw = "".join(chunks)
    suggestions = parse_suggestions(raw)
    if suggestions is None:
        logger.warning("AI suggestions: unparseable output (%d chars): %s", len(raw), raw[:300])
    return suggestions
