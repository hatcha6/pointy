"""The search functions as ORM expressions, on PostgreSQL and on SQLite alike.

On PostgreSQL the functions are SQL (migration ``catalog.0034``) and indexed.
On SQLite — the fast local test path — the Python twins from
:mod:`apps.catalog.search_text` are registered on every new connection under
the same names, so the same queries run there too; only the trigram similarity
fallback, which SQLite has no equivalent for, is skipped.
"""

from __future__ import annotations

from django.db.models import FloatField, Func, TextField

from . import search_text


class SearchFold(Func):
    """``pointy_search_fold(expr)`` — see :func:`search_text.fold`."""

    function = "pointy_search_fold"
    output_field = TextField()


class SearchSkeleton(Func):
    """``pointy_search_skeleton(expr)`` — see :func:`search_text.skeleton`."""

    function = "pointy_search_skeleton"
    output_field = TextField()


class PhoneKey(Func):
    """``pointy_phone_key(expr)`` — see :func:`search_text.phone_key`."""

    function = "pointy_phone_key"
    output_field = TextField()


class WordSimilarity(Func):
    """pg_trgm's ``word_similarity(needle, haystack)``: how well ``needle``
    matches the best-matching stretch of ``haystack`` (0..1). PostgreSQL only."""

    function = "word_similarity"
    output_field = FloatField()


def _sqlite_fold(value):
    return None if value is None else search_text.fold(value)


def _sqlite_skeleton(value):
    return None if value is None else search_text.skeleton(value)


def _sqlite_phone_key(value):
    return None if value is None else search_text.phone_key(value)


def register_sqlite_functions(sender, connection, **kwargs):
    """``connection_created`` receiver: give SQLite the Python twins."""
    if connection.vendor != "sqlite":
        return
    raw = connection.connection
    raw.create_function("pointy_search_fold", 1, _sqlite_fold, deterministic=True)
    raw.create_function(
        "pointy_search_skeleton", 1, _sqlite_skeleton, deterministic=True
    )
    raw.create_function("pointy_phone_key", 1, _sqlite_phone_key, deterministic=True)


def supports_similarity(connection) -> bool:
    """Whether trigram similarity (pg_trgm) is available on ``connection``."""
    return connection.vendor == "postgresql"
