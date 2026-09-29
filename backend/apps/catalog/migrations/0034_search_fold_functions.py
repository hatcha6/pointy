"""Search folds both sides: the SQL half of ``apps.catalog.search_text``.

Until now only the QUERY was normalized, and only lightly: stored names were
compared raw, so folding «ة» to «ه» or «أ» to «ا» on the query would have broken
every match against a name that still carried the original letter. The field
catalogue spells the same word both ways (rice is «أرز» in 58 names and «ارز»
in 57), so no single spelling a cashier types could find every product.

Three IMMUTABLE functions, each mirroring its Python twin in ``search_text``
character for character (``test_search_text`` compares them):

* ``pointy_search_fold(text)`` — the comparison form of a name or a query;
* ``pointy_search_skeleton(text)`` — the loanword key, the last-resort match;
* ``pointy_phone_key(text)`` — the national digits of a Libyan phone number.

0035 stores their results as generated columns and 0036 indexes those.

Additive (expand-only): nothing calls these until the new search ships, so a
release still serving during a live update is unaffected. PostgreSQL only — on
SQLite the functions are registered per connection in Python
(``CatalogConfig.ready``).

Changing a function later means a new migration that replaces it AND rewrites
the generated columns that store its output (``UPDATE ... SET name = name``),
since PostgreSQL does not recompute a stored column when a function changes.
"""

from django.db import migrations

# Kept here verbatim rather than imported from search_text: a migration is a
# record of what was applied, and must not change when the module does. The
# parity test is what keeps the two in step.
_APOSTROPHES = "''\u2019\u2018`\u00b4"  # the apostrophe doubled for the SQL literal
_DROP_CHARS = (
    "\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06ed\u0640"
    "\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff"
)
_FOLD_FROM = (
    "أإآٱ"
    "ىئی"
    "ؤ"
    "ةۀ"
    "ک"
    "٠١٢٣٤٥٦٧٨٩"
    "۰۱۲۳۴۵۶۷۸۹"
    "٫٬،"
)
_FOLD_TO = (
    "اااا"
    "ييي"
    "و"
    "هه"
    "ك"
    "01234567890123456789"
    ".,,"
)
# In an ARE bracket expression «]» goes first, a backslash is escaped, «-» last.
_PUNCTUATION_BRACKET = (
    "[]!\"#$%&()*+:;<=>?@[\\\\^_{|}~"
    "«»؛؟٪٭“”–—…•·-]"
)
_SKELETON_FROM = "جغطضظذصثڤپچ"
_SKELETON_TO = "ققتدززسسفبش"
_ARABIC_DIGITS = (
    "٠١٢٣٤٥٦٧٨٩"
    "۰۱۲۳۴۵۶۷۸۹"
)

CREATE_FOLD = f"""
CREATE OR REPLACE FUNCTION pointy_search_fold(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $fold$
SELECT btrim(regexp_replace(
  regexp_replace(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          translate(
            regexp_replace(
              lower(normalize(regexp_replace(value, '[{_APOSTROPHES}]', '', 'g'), NFKC)),
              '[{_DROP_CHARS}]', '', 'g'),
            '{_FOLD_FROM}', '{_FOLD_TO}'),
          '{_PUNCTUATION_BRACKET}', ' ', 'g'),
        '(?<![0-9])[.,/]|[.,/](?![0-9])', ' ', 'g'),
      '([0-9])([^0-9[:space:].,/])', '\\1 \\2', 'g'),
    '([^0-9[:space:].,/])([0-9])', '\\1 \\2', 'g'),
  '[[:space:]]+', ' ', 'g'))
$fold$;
"""

CREATE_SKELETON = f"""
CREATE OR REPLACE FUNCTION pointy_search_skeleton(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $skeleton$
SELECT btrim(regexp_replace(
  regexp_replace(
    regexp_replace(
      translate(
        regexp_replace(pointy_search_fold(value), '(^| )ال(?=[^ ]{{3}})', '\\1', 'g'),
        '{_SKELETON_FROM}', '{_SKELETON_TO}'),
      '[اوي]', '', 'g'),
    'ه(?= |$)', '', 'g'),
  ' +', ' ', 'g'))
$skeleton$;
"""

CREATE_PHONE_KEY = f"""
CREATE OR REPLACE FUNCTION pointy_phone_key(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $phone$
SELECT regexp_replace(
  regexp_replace(translate(value, '{_ARABIC_DIGITS}', '01234567890123456789'), '[^0-9]', '', 'g'),
  '^(00218|218|0)', '')
$phone$;
"""

def _create(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        cursor.execute(CREATE_FOLD)
        cursor.execute(CREATE_SKELETON)
        cursor.execute(CREATE_PHONE_KEY)


def _drop(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        cursor.execute("DROP FUNCTION IF EXISTS pointy_phone_key(text);")
        cursor.execute("DROP FUNCTION IF EXISTS pointy_search_skeleton(text);")
        cursor.execute("DROP FUNCTION IF EXISTS pointy_search_fold(text);")


class Migration(migrations.Migration):
    dependencies = [
        ("catalog", "0033_productcategory_system_key"),
    ]

    operations = [
        migrations.RunPython(_create, _drop, elidable=False),
    ]
