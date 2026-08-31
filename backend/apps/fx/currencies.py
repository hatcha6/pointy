"""Built-in FX reference data: currencies, settlement instruments, rate sources.

Pure data and constants, no Django imports, so the seed can feed both a data
migration and the runtime seeder without either importing the other — the same
split ``apps.holidays.rules`` uses for the built-in calendar.

**Why these currencies.** The set is the eight pairs ``fulus.ly`` publishes
against the dinar, plus the dinar itself. A Libyan shop's foreign exposure is
overwhelmingly USD (imports priced in dollars), then TRY and EUR (Turkish and
European suppliers), then the regional currencies for cross-border trade. Adding
one later is a row, not a migration of behaviour.

**Why every currency carries two decimal places.** ISO 4217 assigns *three* to
both LYD and TND. Every money column in this product is ``decimal_places=2``,
so a third place cannot be stored — and a currency registry that claimed three
would round it away silently at the first write. We carry two deliberately, and
``money.MAX_SUPPORTED_DECIMALS`` refuses anything wider so the constraint fails
loudly if the schema and the registry ever disagree. In Libyan retail the dinar
is quoted and handled to two places anyway; the dirham subdivision survives on
banknotes, not on price tags.
"""

from __future__ import annotations

# --- Settlement instrument --------------------------------------------------
# BOTH of these are parallel-market rates. ``bank`` is *not* the official CBL
# rate: it is the parallel rate obtained by settling through a bank — a
# transfer, a letter of credit, a certificate (شهادة) — rather than by handing
# over physical cash, and it is published per bank because that price differs
# between banks. The axis is therefore *how the shop pays*, not *which market*.
#
# We deliberately carry no official rate. If one is ever wanted it is a
# different source with a different meaning, not another value of this field.
INSTRUMENT_CASH = "cash"
INSTRUMENT_BANK = "bank"
INSTRUMENTS = (INSTRUMENT_CASH, INSTRUMENT_BANK)

INSTRUMENT_LABELS_AR = {
    INSTRUMENT_CASH: "نقدًا",
    INSTRUMENT_BANK: "تحويل مصرفي",
}
INSTRUMENT_LABELS_EN = {
    INSTRUMENT_CASH: "Cash",
    INSTRUMENT_BANK: "Bank transfer",
}

# --- Provenance -------------------------------------------------------------
# Mirrors the holidays calendar's three-source model, and for the same reason:
# a shop must keep working when the relay cannot be reached, and a number the
# owner typed must never be overwritten by one that arrived over the wire.
SOURCE_BUILTIN = "builtin"  # shipped seed; a starting point, never authoritative
SOURCE_RELAY = "relay"      # synced from the relay control plane (fulus.ly)
SOURCE_MANUAL = "manual"    # typed by the shop; always wins
SOURCES = (SOURCE_BUILTIN, SOURCE_RELAY, SOURCE_MANUAL)

# --- Currencies -------------------------------------------------------------
# ``code`` is ISO 4217 and is the primary key: stable, and what the feed speaks.
BUILTIN_CURRENCIES = [
    {"code": "LYD", "name_en": "Libyan Dinar", "name_ar": "دينار ليبي",
     "symbol_en": "LYD", "symbol_ar": "د.ل", "display_order": 0},
    {"code": "USD", "name_en": "US Dollar", "name_ar": "دولار أمريكي",
     "symbol_en": "$", "symbol_ar": "$", "display_order": 1},
    {"code": "EUR", "name_en": "Euro", "name_ar": "يورو",
     "symbol_en": "€", "symbol_ar": "€", "display_order": 2},
    {"code": "TRY", "name_en": "Turkish Lira", "name_ar": "ليرة تركية",
     "symbol_en": "₺", "symbol_ar": "₺", "display_order": 3},
    {"code": "GBP", "name_en": "British Pound", "name_ar": "جنيه إسترليني",
     "symbol_en": "£", "symbol_ar": "£", "display_order": 4},
    {"code": "TND", "name_en": "Tunisian Dinar", "name_ar": "دينار تونسي",
     "symbol_en": "DT", "symbol_ar": "د.ت", "display_order": 5},
    {"code": "EGP", "name_en": "Egyptian Pound", "name_ar": "جنيه مصري",
     "symbol_en": "E£", "symbol_ar": "ج.م", "display_order": 6},
    {"code": "SAR", "name_en": "Saudi Riyal", "name_ar": "ريال سعودي",
     "symbol_en": "SR", "symbol_ar": "ر.س", "display_order": 7},
    {"code": "AED", "name_en": "UAE Dirham", "name_ar": "درهم إماراتي",
     "symbol_en": "AED", "symbol_ar": "د.إ", "display_order": 8},
]

BUILTIN_CODES = frozenset(item["code"] for item in BUILTIN_CURRENCIES)

# The shop's own currency unless setup says otherwise. Matches the long-standing
# ``ShopSettings.currency_code`` default, which this does not replace: that
# column *is* the base currency, and always was — it simply had no arithmetic
# meaning until now.
DEFAULT_BASE_CODE = "LYD"

# Decimal places for every built-in. Kept as one constant rather than a per-row
# field because the schema supports exactly one value; see the module docstring.
BUILTIN_DECIMALS = 2


def currency_row_fields(data: dict) -> dict:
    """Normalise a seed mapping into a full set of ``Currency`` field values.

    Shared by the seed migration and the runtime seeder so the defaults have one
    definition, exactly as ``holidays.rules.row_fields`` does.
    """
    return {
        "name_en": data["name_en"],
        "name_ar": data["name_ar"],
        "symbol_en": data.get("symbol_en", ""),
        "symbol_ar": data.get("symbol_ar", ""),
        "decimals": data.get("decimals", BUILTIN_DECIMALS),
        "display_order": data.get("display_order", 0),
        "is_enabled": data.get("is_enabled", True),
    }


def normalize_instrument(value) -> str:
    """Coerce a settlement instrument to a known value, defaulting to cash.

    Cash is the safe default because it is how the overwhelming majority of
    Libyan shops actually pay, and because an unknown instrument arriving from a
    feed must not silently become "no rate at all".
    """
    candidate = str(value or "").strip().lower()
    return candidate if candidate in INSTRUMENTS else INSTRUMENT_CASH


def normalize_bank_code(value, *, instrument: str = INSTRUMENT_CASH) -> str:
    """Canonical bank slug, blank unless the instrument is a bank settlement.

    A bank code on a cash rate is meaningless and would fragment the uniqueness
    key, so it is dropped rather than stored.
    """
    if normalize_instrument(instrument) != INSTRUMENT_BANK:
        return ""
    return str(value or "").strip().lower()
