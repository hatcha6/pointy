"""List search that reads text the way people type it, not the way it was saved.

DRF's stock ``SearchFilter`` compares every typed word with ``icontains``
against the raw column, so a record is found only when it is typed the way it
was saved — and nobody types it that way. «احمد» never found «أحمد», «مكرونه»
never found «مكرونة», and a phone typed «+218 91-234 5678» or «091 234 5678»
never found the customer saved as «0912345678» — and field telemetry shows staff
typing customers' phone numbers into these boxes.

:class:`FoldingSearchFilter` keeps every rule of the stock filter — the search
split into terms on spaces and commas, every term required, any one search
field enough for a term, relations followed, duplicates removed with
``EXISTS``, the ``^ = @ $`` prefixes — and changes only how a term compares:

* a plain text field compares FOLDED text on both sides: the same
  ``pointy_search_fold`` the product search uses (``apps.catalog.search_text``);
* a phone field (``phone``, ``customer__phone``, ``mobile_phone``) compares the
  national digits (``pointy_phone_key``) when the term is a phone number, so
  every way of writing one number is that number;
* a search that is one phone number written with spaces stays one term.

A viewset opts in with ``filter_backends = FOLDING_FILTER_BACKENDS``. The folding
runs per row at query time — nothing stored, nothing indexed. Measured on
PostgreSQL that is roughly 15 µs a customer row against well under 1 µs for
``icontains``: some 150 ms at ten thousand customers, and pagination's COUNT
pays it again. Right for lists of customers, suppliers and jobs; wrong for the
invoice and purchase-order lists, whose search reaches through every order line
— those keep the stock filter. A list that outgrows it wants what the product
search has: the folded text stored in a generated column, trigram-indexed.
"""

from __future__ import annotations

from django.core.exceptions import FieldDoesNotExist
from django.db.models import CharField, Lookup, TextField, Value
from django.db.models.constants import LOOKUP_SEP
from django_filters.rest_framework import DjangoFilterBackend
from rest_framework.filters import OrderingFilter, SearchFilter

from apps.catalog import search_text
from apps.catalog.search_sql import PhoneKey, SearchFold

FOLDED_CONTAINS = "pfold_contains"
PHONE_CONTAINS = "pphone_contains"

# E.164 caps a phone number at 15 digits, and a Libyan one written in full
# (00218 91 234 5678) has 14. A digit run longer than that is two numbers, or
# not a phone at all, and is searched word by word like any other text.
MAX_PHONE_DIGITS = 15


def _compiled(compiler, expression):
    return compiler.compile(expression.resolve_expression(compiler.query))


class _KeyContains(Lookup):
    """``key(field)`` contains ``key(term)``, with ``key`` one SQL function.

    Both sides pass through the same function, so a stored value and a typed one
    are compared in one form however either was written, and the match never
    depends on the Python twin agreeing with the SQL. The planner folds the
    term's side once, as a constant. Its LIKE wildcards are escaped after
    folding — the fold already turns ``%`` and ``_`` into spaces, but a later
    change to it must not turn a search into a pattern.
    """

    def key_for(self, term):
        return SearchFold

    def as_sql(self, compiler, connection):
        key = self.key_for(self.rhs)
        term = self.rhs if hasattr(self.rhs, "resolve_expression") else Value(self.rhs)
        lhs_sql, lhs_params = _compiled(compiler, key(self.lhs))
        rhs_sql, rhs_params = _compiled(compiler, key(term))
        pattern = connection.pattern_ops["contains"].format(connection.pattern_esc.format(rhs_sql))
        return f"{lhs_sql} {pattern}", [*lhs_params, *rhs_params]


@CharField.register_lookup
@TextField.register_lookup
class FoldedContains(_KeyContains):
    """``field__pfold_contains=term``: «احمد» finds «أحمد», «مكرونه» «مكرونة»."""

    lookup_name = FOLDED_CONTAINS


@CharField.register_lookup
@TextField.register_lookup
class PhoneContains(_KeyContains):
    """``field__pphone_contains=term``: a phone number in any spelling.

    A term that is a phone number compares national digits, so «+218 91-234
    5678», «00218912345678» and «٠٩١٢٣٤٥٦٧٨» all find «0912345678». Anything
    else — a name typed into the box, four remembered digits — is an ordinary
    folded contains: stripping a «0» or «218» off a fragment would be guessing.
    """

    lookup_name = PHONE_CONTAINS

    def key_for(self, term):
        if isinstance(term, str) and search_text.looks_like_phone(term):
            return PhoneKey
        return SearchFold


def is_phone_field(field_name: str) -> bool:
    """``phone``, ``customer__phone``, ``mobile_phone`` — a field holding a number."""
    name = field_name.rsplit(LOOKUP_SEP, 1)[-1]
    return name == "phone" or name.endswith("_phone")


def is_one_phone_number(text: str) -> bool:
    """A whole search that is a single phone number, spaces and all."""
    return search_text.looks_like_phone(text) and (
        sum(char.isdecimal() for char in text) <= MAX_PHONE_DIGITS
    )


def _model_field(model, field_path):
    """The field a search-field path ends on, following relations; None when
    the path names something else (an annotation, a transform)."""
    opts = model._meta
    field = None
    for part in field_path.split(LOOKUP_SEP):
        try:
            field = opts.get_field(opts.pk.name if part == "pk" else part)
        except FieldDoesNotExist:
            return None
        if hasattr(field, "path_infos"):
            opts = field.path_infos[-1].to_opts
    return field


class FoldingSearchFilter(SearchFilter):
    """DRF's ``SearchFilter``, comparing folded text and phone numbers."""

    def get_search_terms(self, request):
        terms = super().get_search_terms(request)
        if len(terms) > 1:
            # Split on its spaces, «091 234 5678» would be three numbers each
            # found anywhere in any field — and would find «0915678234» too.
            whole = request.query_params.get(self.search_param, "").strip()
            if is_one_phone_number(whole):
                # As its digits alone: a phone field reads its phone key from
                # them, and a code typed in groups — an IMEI «35 6789 …» —
                # still finds the unbroken code a text field stores.
                return ["".join(ch for ch in search_text.code_form(whole) if ch.isdigit())]
        return terms

    def construct_search(self, field_name, queryset):
        lookup = super().construct_search(field_name, queryset)
        if lookup != f"{field_name}{LOOKUP_SEP}icontains":
            # A ^ = @ $ prefix, or a lookup the field name spells out itself:
            # the stock meaning stands.
            return lookup
        folded = PHONE_CONTAINS if is_phone_field(field_name) else FOLDED_CONTAINS
        field = _model_field(queryset.model, field_name)
        if field is None or field.get_lookup(folded) is None:
            return lookup  # not a text column: nothing to fold
        return f"{field_name}{LOOKUP_SEP}{folded}"


# The project default (settings.REST_FRAMEWORK["DEFAULT_FILTER_BACKENDS"]) with
# the search swapped; ``test_folding_search_filter`` holds the two in step.
FOLDING_FILTER_BACKENDS = (DjangoFilterBackend, FoldingSearchFilter, OrderingFilter)
