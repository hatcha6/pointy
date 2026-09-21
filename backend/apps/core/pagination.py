"""Pagination classes shared across the API."""

from rest_framework.exceptions import NotFound
from rest_framework.pagination import BasePagination, CursorPagination
from rest_framework.response import Response
from rest_framework.utils.urls import remove_query_param, replace_query_param


class CreatedAtCursorPagination(CursorPagination):
    """Keyset pagination for newest-first feeds that are still being written to.

    Page-number pagination resolves every page to an OFFSET into a live list. On
    a ``-created_at`` feed each new row lands at the *head* and pushes the whole
    list down, so the second page — fetched a moment later — starts one row too
    early: the boundary rows come back a second time while the rows written since
    page one, already behind the offset the client consumed, are never returned
    at all.

    On a register session that is still selling, that is not cosmetic: sales rung
    up while the shift is being reviewed silently vanish from the session's list,
    and a drawer opened while the history list is being scrolled never appears in
    it. A cursor anchors each page to the last row the client actually saw, so a
    concurrent write can neither skip nor duplicate a row.

    ``count`` is intentionally absent from the response (a keyset window has no
    total); clients page until ``next`` is null.
    """

    ordering = "-created_at"
    page_size = 50
    page_size_query_param = "page_size"
    max_page_size = 200


class OccurredAtCursorPagination(CursorPagination):
    """Keyset paging for the event log, newest first.

    Same reasoning as ``CreatedAtCursorPagination`` — the log is appended to
    every second — plus one more: page-number paging ran an exact ``COUNT(*)``
    over the filtered set for every page, a full scan of a table that holds a
    month of telemetry. No count is served; clients page until ``next`` is
    null. ``id`` breaks ties within a second so a burst of same-instant rows
    can neither repeat nor go missing across a page boundary.
    """

    ordering = ("-occurred_at", "-id")
    page_size = 50
    page_size_query_param = "page_size"
    max_page_size = 200


class UncountedPageNumberPagination(BasePagination):
    """Page-number paging that never runs ``COUNT(*)``.

    Ordinary page-number paging answers every request twice: once to count the
    filtered set and once to fetch the page. That is free when the filter is an
    index lookup and ruinous when it is not.

    ``purchaseorder-outstanding-received-not-paid`` is the second kind. Its
    filter is "billable total still exceeds everything paid against it", a
    correlated aggregate that cannot be indexed, so each execution walks every
    received order the shop has ever had — 11,700 of them at the field shop, to
    return fifty rows. The 2026-09-16 export measured 581ms of database time
    per request, and it grows with every delivery the shop takes in.

    So the count is dropped rather than made faster. ``next`` comes from a
    single look-ahead row (fetch ``page_size + 1``, serve ``page_size``), which
    is what the client actually reads — it pages until ``next`` is null and has
    no use for a total. Responses keep the ``next``/``previous``/``results``
    shape; only ``count`` is absent.
    """

    page_size = 50
    page_query_param = "page"
    page_size_query_param = "page_size"
    max_page_size = 200
    invalid_page_message = "Invalid page: {message}."

    def get_page_size(self, request):
        if self.page_size_query_param:
            try:
                requested = int(request.query_params[self.page_size_query_param])
            except (KeyError, TypeError, ValueError):
                requested = None
            if requested is not None and requested > 0:
                return min(requested, self.max_page_size)
        return self.page_size

    def paginate_queryset(self, queryset, request, view=None):
        self.request = request
        page_size = self.get_page_size(request)
        if not page_size:
            return None
        raw = request.query_params.get(self.page_query_param, 1)
        try:
            page_number = int(raw)
        except (TypeError, ValueError):
            raise NotFound(self.invalid_page_message.format(message="not a number"))
        if page_number < 1:
            raise NotFound(self.invalid_page_message.format(message="below 1"))

        self.page_number = page_number
        self.served_size = page_size
        offset = (page_number - 1) * page_size
        # One row past the page: its presence is the whole answer to "is there
        # a next page", and it costs one row instead of a second full scan.
        window = list(queryset[offset : offset + page_size + 1])
        self.has_next = len(window) > page_size
        return window[:page_size]

    def get_next_link(self):
        if not self.has_next:
            return None
        url = self.request.build_absolute_uri()
        return replace_query_param(url, self.page_query_param, self.page_number + 1)

    def get_previous_link(self):
        if self.page_number <= 1:
            return None
        url = self.request.build_absolute_uri()
        if self.page_number == 2:
            return remove_query_param(url, self.page_query_param)
        return replace_query_param(url, self.page_query_param, self.page_number - 1)

    def get_paginated_response(self, data):
        return Response(
            {
                "next": self.get_next_link(),
                "previous": self.get_previous_link(),
                "results": data,
            }
        )
