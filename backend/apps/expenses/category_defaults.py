"""Seed data for expense categories.

Shared by the seeding migration and the initial-setup check in
``apps/core/roles.py`` so a freshly seeded shop (categories only, no recorded
expenses) is still treated as "not set up yet" — the same way the built-in POS
sales channel and default variant options are treated.
"""

# (name, display_order). Arabic-first, matching the rest of the product.
DEFAULT_EXPENSE_CATEGORIES = (
    ("إيجار", 1),  # rent
    ("كهرباء وماء", 2),  # utilities (electricity & water)
    ("صيانة", 3),  # maintenance
    ("مستلزمات", 4),  # supplies
    ("نقل ومواصلات", 5),  # transport
    ("تسويق ودعاية", 6),  # marketing
    ("رسوم وعمولات", 7),  # fees
    ("أخرى", 8),  # other
)

DEFAULT_EXPENSE_CATEGORY_NAMES = frozenset(
    name for name, _display_order in DEFAULT_EXPENSE_CATEGORIES
)
