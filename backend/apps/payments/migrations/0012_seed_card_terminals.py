"""Give the shop's existing trusted terminals a row of their own.

``ShopSettings.trusted_card_terminal_ids`` was the whole registry: a list of
strings, with no bank behind them. It stays — as a mirror written only by
``apps.payments.terminals`` — but the rows become the thing an owner edits, and
the thing a terminal's bank account hangs off.

A shop that never listed a terminal gets no rows, and keeps allowing any
terminal. That is the pre-existing default and this migration does not change
it: an empty registry means "not restricted", exactly as an empty list did.
"""

from django.db import migrations


def normalize(value):
    return "".join(
        character for character in str(value or "").upper() if character.isalnum()
    )


def seed(apps, schema_editor):
    ShopSettings = apps.get_model("core", "ShopSettings")
    CardTerminal = apps.get_model("payments", "CardTerminal")

    settings = ShopSettings.objects.first()
    if settings is None:
        return
    seen = set()
    order = 0
    for value in settings.trusted_card_terminal_ids or []:
        terminal_id = normalize(value)
        if not terminal_id or terminal_id in seen:
            continue
        seen.add(terminal_id)
        CardTerminal.objects.get_or_create(
            terminal_id=terminal_id,
            defaults={"display_order": order},
        )
        order += 1


def unseed(apps, schema_editor):
    # The settings list is untouched by ``seed``, so it is still the complete
    # record and dropping the rows loses nothing.
    apps.get_model("payments", "CardTerminal").objects.all().delete()


class Migration(migrations.Migration):
    dependencies = [
        ("payments", "0011_cardterminal_payment_money_account_and_more"),
        ("core", "0036_shopsettings_max_invoice_discount_amount"),
    ]

    operations = [migrations.RunPython(seed, unseed)]
