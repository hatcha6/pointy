"""Typed, per-article facts — battery health, shutter count, cosmetic grade.

The narrow slice of custom fields that a used-goods trade genuinely cannot work
without, and deliberately not one inch wider. The general case — a metadata
engine with its own doctypes — is an explicit anti-goal, and the standard next
mistake is an ``attribute_name / attribute_value`` table: an EAV join per
attribute, untyped values, and no way to ask *"which handsets have a battery
above 85%?"*.

So: definitions hang off the ``AssetType`` a shop already maintains for its
workshop, and values live in one JSONB column on the unit. One row, one read, no
join, and Postgres containment and range operators do the filtering. Numbers are
stored as numbers, which is the whole reason ``85`` sorts above ``9``.
"""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal, InvalidOperation

from rest_framework import serializers

from .models import UnitAttributeDefinition

DataType = UnitAttributeDefinition.DataType


def _choice(value, label):
    return {"value": value, "label": label}


#: Definitions seeded per asset-type slug, so a shop entering a serialized trade
#: gets sensible condition, feature and accessory fields without designing a
#: schema by hand. Ordered as an intake sheet reads: what it is, then what
#: condition it is in, then what came in the box.
SEEDED_TEMPLATES: dict[str, list[dict]] = {
    "phone": [
        {
            "key": "battery_health",
            "label": "صحة البطارية",
            "data_type": DataType.PERCENT,
            "suffix": "%",
            "show_in_picker": True,
            "is_filterable": True,
        },
        {
            "key": "condition_grade",
            "label": "درجة الحالة",
            "data_type": DataType.CHOICE,
            "choices": [
                _choice("a_plus", "ممتاز +"),
                _choice("a", "ممتاز"),
                _choice("b", "جيد"),
                _choice("c", "مقبول"),
                _choice("parts", "قطع غيار"),
            ],
            "show_in_picker": True,
            "show_on_label": True,
            "is_filterable": True,
        },
        {
            "key": "carrier_lock",
            "label": "قفل الشبكة / الحساب",
            "data_type": DataType.CHOICE,
            "choices": [
                _choice("unlocked", "مفتوح"),
                _choice("locked", "مقفل"),
            ],
            "show_in_picker": True,
        },
        {
            "key": "box_and_accessories",
            "label": "العلبة والملحقات",
            "data_type": DataType.CHOICE,
            "choices": [
                _choice("full_box", "علبة كاملة"),
                _choice("charger", "مع الشاحن"),
                _choice("device_only", "الجهاز فقط"),
            ],
            "show_on_receipt": True,
        },
    ],
    "laptop": [
        {"key": "processor_cpu", "label": "المعالج", "data_type": DataType.TEXT,
         "show_in_picker": True},
        {"key": "ram_size_gb", "label": "الذاكرة", "data_type": DataType.NUMBER,
         "suffix": "GB", "show_in_picker": True, "is_filterable": True},
        {"key": "storage_capacity", "label": "التخزين", "data_type": DataType.TEXT,
         "show_in_picker": True},
        {"key": "battery_cycle_count", "label": "دورات البطارية",
         "data_type": DataType.NUMBER},
        {"key": "gpu_graphics", "label": "كرت الشاشة", "data_type": DataType.TEXT},
        {"key": "charger_included", "label": "الشاحن مرفق",
         "data_type": DataType.BOOL, "show_on_receipt": True},
        {
            "key": "condition_grade",
            "label": "درجة الحالة",
            "data_type": DataType.CHOICE,
            "choices": [
                _choice("excellent", "ممتاز"),
                _choice("good", "جيد"),
                _choice("fair", "مقبول"),
            ],
            "show_on_label": True,
            "is_filterable": True,
        },
    ],
    "console": [
        {"key": "storage_gb", "label": "سعة التخزين", "data_type": DataType.NUMBER,
         "suffix": "GB", "show_in_picker": True},
        {"key": "firmware_version", "label": "إصدار النظام", "data_type": DataType.TEXT},
        {"key": "controller_count", "label": "عدد أذرع التحكم",
         "data_type": DataType.NUMBER, "show_on_receipt": True},
        {"key": "original_box", "label": "العلبة الأصلية", "data_type": DataType.BOOL},
        {
            "key": "online_ban_status",
            "label": "حالة الحساب",
            "data_type": DataType.CHOICE,
            "choices": [_choice("clean", "سليم"), _choice("banned", "محظور")],
            "show_in_picker": True,
        },
    ],
    "appliance": [
        {"key": "screen_size_inches", "label": "حجم الشاشة",
         "data_type": DataType.NUMBER, "suffix": "\"", "show_in_picker": True},
        {"key": "panel_lamp_hours", "label": "ساعات التشغيل",
         "data_type": DataType.NUMBER, "suffix": "hrs"},
        {"key": "stand_remote_included", "label": "القاعدة والريموت",
         "data_type": DataType.BOOL, "show_on_receipt": True},
        {
            "key": "cosmetic_condition",
            "label": "الحالة الظاهرية",
            "data_type": DataType.CHOICE,
            "choices": [
                _choice("like_new", "كالجديد"),
                _choice("scratches", "خدوش خفيفة"),
                _choice("dented", "منبعج"),
            ],
            "show_on_label": True,
        },
    ],
    "vehicle": [
        {"key": "mileage", "label": "العداد", "data_type": DataType.NUMBER,
         "suffix": "km", "show_in_picker": True, "is_filterable": True},
        {"key": "model_year", "label": "سنة الصنع", "data_type": DataType.NUMBER,
         "show_in_picker": True, "is_filterable": True},
        {"key": "colour", "label": "اللون", "data_type": DataType.TEXT,
         "show_in_picker": True},
        {"key": "keys_count", "label": "عدد المفاتيح", "data_type": DataType.NUMBER,
         "show_on_receipt": True},
        {
            "key": "title_status",
            "label": "حالة الملكية",
            "data_type": DataType.CHOICE,
            "choices": [_choice("clean", "سليمة"), _choice("rebuilt", "مُعاد بناؤها")],
        },
    ],
}
#: A tablet is a phone with a bigger screen, as far as an intake sheet is
#: concerned.
SEEDED_TEMPLATES["tablet"] = SEEDED_TEMPLATES["phone"]


def seed_definitions(asset_type_model, definition_model, *, slugs=None):
    """Create the seeded definitions for each asset type that has a template.

    Idempotent by ``(asset_type, key)``: re-running it never duplicates a field
    and never overwrites a label a shop has edited.
    """
    created = 0
    wanted = slugs or list(SEEDED_TEMPLATES)
    for asset_type in asset_type_model.objects.filter(slug__in=wanted):
        for order, row in enumerate(SEEDED_TEMPLATES.get(asset_type.slug, [])):
            _, was_created = definition_model.objects.get_or_create(
                asset_type_id=asset_type.pk,
                key=row["key"],
                defaults={
                    "label": row["label"],
                    "data_type": row["data_type"],
                    "choices": row.get("choices", []),
                    "suffix": row.get("suffix", ""),
                    "is_required": row.get("is_required", False),
                    "show_in_picker": row.get("show_in_picker", False),
                    "show_on_label": row.get("show_on_label", False),
                    "show_on_receipt": row.get("show_on_receipt", False),
                    "is_filterable": row.get("is_filterable", False),
                    "display_order": order,
                },
            )
            created += int(was_created)
    return created


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def definitions_for(asset_type_id):
    if not asset_type_id:
        return []
    return list(
        UnitAttributeDefinition.objects.filter(asset_type_id=asset_type_id).order_by(
            "display_order", "id"
        )
    )


def _coerce(definition, value):
    """One attribute's value, in the type the definition promised.

    Raises ``ValueError`` with an Arabic message; the caller decides which field
    the message belongs under.
    """
    kind = definition.data_type
    if value in (None, ""):
        return None
    if kind == DataType.BOOL:
        if isinstance(value, bool):
            return value
        text = str(value).strip().lower()
        if text in {"true", "1", "yes", "نعم"}:
            return True
        if text in {"false", "0", "no", "لا"}:
            return False
        raise ValueError(f"«{definition.label}» يقبل نعم أو لا فقط.")
    if kind in (DataType.NUMBER, DataType.PERCENT, DataType.MONEY):
        try:
            number = Decimal(str(value))
        except (InvalidOperation, TypeError):
            raise ValueError(f"«{definition.label}» يجب أن يكون رقمًا.") from None
        if kind == DataType.PERCENT and not (0 <= number <= 100):
            raise ValueError(f"«{definition.label}» نسبة بين 0 و 100.")
        # Stored as a JSON number so ``attributes->>'battery_health' >= 85``
        # compares as a number rather than as the string "9" beating "85".
        return float(number)
    if kind == DataType.DATE:
        if isinstance(value, (date, datetime)):
            return value.isoformat()[:10]
        text = str(value).strip()
        try:
            date.fromisoformat(text[:10])
        except ValueError:
            raise ValueError(f"«{definition.label}» تاريخ غير صالح.") from None
        return text[:10]
    if kind == DataType.CHOICE:
        allowed = {
            str(choice.get("value"))
            for choice in definition.choices or []
            if isinstance(choice, dict)
        }
        text = str(value)
        if allowed and text not in allowed:
            raise ValueError(f"«{definition.label}» قيمة غير مسموح بها.")
        return text
    return str(value)


def validate_attributes(attributes, *, asset_type_id, definitions=None, partial=False):
    """Coerce and check one unit's attributes against its type's definitions.

    Unknown keys are dropped rather than refused: a shop that deletes a
    definition has not invalidated the articles that carried it, and a 400 on
    every subsequent save of those articles would be a worse answer than
    quietly ceasing to show a field nobody defines any more.
    """
    attributes = dict(attributes or {})
    definitions = (
        definitions if definitions is not None else definitions_for(asset_type_id)
    )
    if not definitions:
        return {}
    by_key = {definition.key: definition for definition in definitions}
    cleaned = {}
    errors = {}
    for key, value in attributes.items():
        definition = by_key.get(key)
        if definition is None:
            continue
        try:
            coerced = _coerce(definition, value)
        except ValueError as error:
            errors[key] = str(error)
            continue
        if coerced is not None:
            cleaned[key] = coerced
    if not partial:
        for definition in definitions:
            if definition.is_required and definition.key not in cleaned:
                errors[definition.key] = f"«{definition.label}» مطلوب."
    if errors:
        raise serializers.ValidationError({"attributes": errors})
    return cleaned


def clean_unit_attributes(attributes, *, asset_type_id, partial=True):
    """What a unit of a product with ``asset_type_id`` may store.

    A product with no asset type has no definitions to answer to, so its
    attributes are kept as written — the same rule the unit's own serializer
    has always applied. With one, every value is coerced against the type's
    definitions and a key nobody defines is dropped (see
    :func:`validate_attributes`).
    """
    if asset_type_id is None:
        return dict(attributes or {})
    return validate_attributes(
        attributes, asset_type_id=asset_type_id, partial=partial
    )


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

#: Serializer-context key holding every definition, grouped by asset type.
_CONTEXT_KEY = "_unit_attribute_definitions"


def definitions_by_type(context=None) -> dict:
    """``{asset_type_id: [definition, ...]}`` for the whole shop, read once.

    The table is a few dozen rows for the busiest shop, so one unfiltered read
    per response beats a query per asset type on a page of units — and a list
    of fifty handsets showing their battery health costs exactly one extra
    query, not fifty.
    """
    if context is not None and _CONTEXT_KEY in context:
        return context[_CONTEXT_KEY]
    grouped: dict = {}
    for definition in UnitAttributeDefinition.objects.order_by(
        "asset_type_id", "display_order", "id"
    ):
        grouped.setdefault(definition.asset_type_id, []).append(definition)
    if context is not None:
        context[_CONTEXT_KEY] = grouped
    return grouped


def _format_number(value) -> str:
    number = float(value)
    return str(int(number)) if number.is_integer() else f"{number:g}"


def display_value(definition, value) -> str:
    """One stored value as a person reads it: a choice's label rather than its
    code, نعم/لا for a yes/no, a number with its suffix."""
    kind = definition.data_type
    if kind == DataType.CHOICE:
        for choice in definition.choices or []:
            if isinstance(choice, dict) and str(choice.get("value")) == str(value):
                return str(choice.get("label") or value)
        return str(value)
    if kind == DataType.BOOL:
        return "نعم" if value in (True, "true", "1", 1) else "لا"
    if kind in (DataType.NUMBER, DataType.PERCENT, DataType.MONEY):
        try:
            text = _format_number(value)
        except (TypeError, ValueError):
            text = str(value)
        suffix = definition.suffix or ("%" if kind == DataType.PERCENT else "")
        if not suffix:
            return text
        # A percent sign and an inch mark hug the number; a unit word does not.
        return f"{text}{suffix}" if suffix in ("%", '"') else f"{text} {suffix}"
    return str(value)


def attribute_display(attributes, definitions) -> list[dict]:
    """A unit's facts in the type's own order, labelled and formatted.

    Only what the definitions still describe: a key the shop has since removed
    is not shown as a raw code nobody can read.
    """
    attributes = attributes or {}
    rows = []
    for definition in definitions or []:
        if definition.key not in attributes:
            continue
        value = attributes[definition.key]
        if value in (None, ""):
            continue
        rows.append(
            {
                "key": definition.key,
                "label": definition.label,
                "value": value,
                "display": display_value(definition, value),
                "data_type": definition.data_type,
                "show_in_picker": definition.show_in_picker,
            }
        )
    return rows


def describe_change(before, after, definitions) -> tuple[str, str, str]:
    """``(from, to, note)`` for the §6.9 event of an attribute edit.

    The note names what changed in Arabic — «صحة البطارية، درجة الحالة» — so
    the timeline answers *what* without the reader diffing two JSON blobs.
    """
    before = before or {}
    after = after or {}
    labels = {definition.key: definition for definition in definitions or []}
    changed = [
        key
        for key in sorted(set(before) | set(after))
        if before.get(key) != after.get(key)
    ]

    def render(values):
        parts = []
        for key in changed:
            if key not in values:
                continue
            definition = labels.get(key)
            text = (
                display_value(definition, values[key])
                if definition is not None
                else str(values[key])
            )
            parts.append(f"{definition.label if definition else key}: {text}")
        return "، ".join(parts)

    note = "، ".join(
        labels[key].label if key in labels else key for key in changed
    )
    return render(before), render(after), note


__all__ = [
    "SEEDED_TEMPLATES",
    "attribute_display",
    "clean_unit_attributes",
    "definitions_by_type",
    "definitions_for",
    "describe_change",
    "display_value",
    "seed_definitions",
    "validate_attributes",
]
