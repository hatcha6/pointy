"""The scale label layout a shop starts with.

Before scale rules were configurable the till read *any* 13-digit code starting
with 2 as "prefix, five-digit item code, five digits of grams". Shops are
running on that today with labels already on shelves, so the seeded rule is
that exact layout rather than the tidier GS1 split (21 weight / 23 price) —
doing anything else would change what a sticker means on an existing install.

The constant lives here rather than in the migration because two other places
need to recognise this row as *seed data*: the initial-setup check in
``apps.core.roles`` (a migration-created row must not make a fresh install look
like a shop that has already started work) and anything else that has to tell
scaffolding from something the shop did.
"""

SEEDED_SCALE_RULE_PATTERN = "2XIIIIIVVVVVC"

SEEDED_SCALE_RULE = {
    "name": "ميزان (وزن بالجرام)",
    "pattern": SEEDED_SCALE_RULE_PATTERN,
    "value_kind": "weight",
    "value_decimals": 3,
    "value_unit": "kg",
    "require_check_digit": True,
    "is_active": True,
    # High, so every rule a shop adds later — necessarily more specific than
    # "any second digit" — is ordered ahead of it.
    "sequence": 100,
}
