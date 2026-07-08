"""Benchmark the `/api/products/` catalog search end to end on real data.

For each search term it drives the *actual* ``ProductViewSet`` code path
(``get_queryset`` + ``filter_queryset`` + pagination + serialization) and
splits the cost into:

* ``fetch``  — the SQL to find + prefetch the page (query count + summed DB time)
* ``ser``    — queries fired *during* serialization (the N+1 smoking gun) + wall time
* ``payload``— the rendered JSON size the client must parse (total + per row)

Run against a copy of the client's data, e.g.::

    DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/pointy_bench \\
        python manage.py benchmark_catalog_search --terms الجيد جبن 100
"""

from __future__ import annotations

import time

from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser
from django.core.management.base import BaseCommand
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework.renderers import JSONRenderer
from rest_framework.request import Request
from rest_framework.test import APIRequestFactory

from apps.catalog.views import ProductViewSet

DEFAULT_TERMS = ["الجيد", "جبن", "حليب", "ماء", "100"]


def _build_view(term: str, user) -> ProductViewSet:
    factory = APIRequestFactory()
    django_request = factory.get(
        "/api/products/",
        {"search": term, "is_active": "true", "ordering": "-popularity", "page": "1"},
    )
    django_request.user = user
    drf_request = Request(django_request)
    drf_request.user = user
    view = ProductViewSet()
    view.request = drf_request
    view.action = "list"
    view.format_kwarg = None
    view.kwargs = {}
    view.args = ()
    return view


class Command(BaseCommand):
    help = "Benchmark /api/products/ search: fetch vs serialization vs payload on real data."

    def add_arguments(self, parser):
        parser.add_argument("--terms", nargs="*", default=None)
        parser.add_argument("--repeat", type=int, default=3, help="runs per term; best (min total) is reported")

    def handle(self, *args, **opts):
        User = get_user_model()
        user = User.objects.filter(is_superuser=True).first() or User.objects.first() or AnonymousUser()
        terms = opts["terms"] or DEFAULT_TERMS
        repeat = max(1, opts["repeat"])
        renderer = JSONRenderer()

        header = (
            f"{'term':<10}{'matches':>8}{'rows':>5}{'fetch_q':>8}{'fetch_ms':>9}"
            f"{'ser_q':>7}{'ser_ms':>9}{'total_ms':>9}{'kb':>8}{'kb/row':>8}"
        )
        self.stdout.write(header)
        self.stdout.write("-" * len(header))

        for term in terms:
            best = None
            for _ in range(repeat):
                view = _build_view(term, user)
                with CaptureQueriesContext(connection) as fetch_ctx:
                    queryset = view.filter_queryset(view.get_queryset())
                    page = view.paginate_queryset(queryset)
                fetch_q = len(fetch_ctx.captured_queries)
                fetch_ms = sum(float(q["time"]) for q in fetch_ctx.captured_queries) * 1000.0
                matches = view.paginator.page.paginator.count

                with CaptureQueriesContext(connection) as ser_ctx:
                    started = time.perf_counter()
                    body = renderer.render(view.get_serializer(page, many=True).data)
                    ser_ms = (time.perf_counter() - started) * 1000.0
                ser_q = len(ser_ctx.captured_queries)

                rows = max(1, len(page))
                kb = len(body) / 1024.0
                total_ms = fetch_ms + ser_ms
                candidate = (matches, rows, fetch_q, fetch_ms, ser_q, ser_ms, total_ms, kb, kb / rows)
                if best is None or candidate[6] < best[6]:
                    best = candidate

            m, rows, fq, fms, sq, sms, tms, kb, kbrow = best
            self.stdout.write(
                f"{term:<10}{m:>8}{rows:>5}{fq:>8}{fms:>9.1f}"
                f"{sq:>7}{sms:>9.1f}{tms:>9.1f}{kb:>8.1f}{kbrow:>8.1f}"
            )
