DEFAULT_VARIANT_OPTIONS = [
    {
        "code": "size",
        "name": "الحجم",
        "display_order": 10,
        "values": [
            ("small", "صغير", 10),
            ("medium", "وسط", 20),
            ("large", "كبير", 30),
            ("family", "عائلي", 40),
        ],
    },
    {
        "code": "color",
        "name": "اللون",
        "display_order": 20,
        "values": [
            ("black", "أسود", 10),
            ("white", "أبيض", 20),
            ("red", "أحمر", 30),
            ("blue", "أزرق", 40),
            ("green", "أخضر", 50),
        ],
    },
    {
        "code": "flavor",
        "name": "النكهة",
        "display_order": 30,
        "values": [
            ("regular", "عادي", 10),
            ("spicy", "حار", 20),
            ("mint", "نعناع", 30),
            ("chocolate", "شوكولاتة", 40),
        ],
    },
    {
        "code": "packaging",
        "name": "العبوة",
        "display_order": 40,
        "values": [
            ("single", "قطعة", 10),
            ("pack", "عبوة", 20),
            ("box", "كرتون", 30),
        ],
    },
]


def seed_variant_options(*, option_model=None, value_model=None):
    from .models import VariantOption, VariantOptionValue

    option_model = option_model or VariantOption
    value_model = value_model or VariantOptionValue
    created = {"options": 0, "values": 0}

    for option_data in DEFAULT_VARIANT_OPTIONS:
        option, option_created = option_model.objects.update_or_create(
            code=option_data["code"],
            defaults={
                "name": option_data["name"],
                "display_order": option_data["display_order"],
                "is_active": True,
            },
        )
        created["options"] += int(option_created)

        for code, name, display_order in option_data["values"]:
            _, value_created = value_model.objects.update_or_create(
                option=option,
                code=code,
                defaults={
                    "name": name,
                    "display_order": display_order,
                    "is_active": True,
                },
            )
            created["values"] += int(value_created)

    return created
