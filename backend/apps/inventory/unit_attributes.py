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


__all__ = [
    "SEEDED_TEMPLATES",
    "definitions_for",
    "seed_definitions",
    "validate_attributes",
]
