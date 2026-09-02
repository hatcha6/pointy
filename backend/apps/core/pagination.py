"""Pagination classes shared across the API."""

from rest_framework.pagination import CursorPagination


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
