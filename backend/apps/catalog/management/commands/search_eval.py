"""Does search find what people meant? Measured on this database's catalogue.

Two kinds of case, both driven through the real product list the till calls
(``ProductViewSet`` with ``system=sellable``), serializer and all:

* **Recorded cases** (``--cases``, default ``search_eval_cases.json``): what
  cashiers really typed when a search failed, from field telemetry, with a
  word the product they meant has in its name. A case whose product this
  catalogue does not carry is skipped, not failed.
* **Generated cases** (``--synthetic N``): N products picked from this
  catalogue (seeded, so a re-run picks the same ones), each searched the ways
  people get a name "wrong" — words in another order, the first and last word
  (item + size), no hamza and «ه» for «ة», a size typed apart from the word it
  is glued to.

Reports how often the meant product is in the first 1 / 5 / 10 results and on
the first page at all (50 rows), per kind, and how long the searches took. Run it against a copy of a shop's data::

    DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/pointy_copy \\
        python manage.py search_eval --synthetic 300
"""

from __future__ import annotations

import json
import random
import re
import statistics
import time
from pathlib import Path

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from rest_framework.test import APIRequestFactory, force_authenticate

from apps.catalog import search_text
from apps.catalog.models import Product
from apps.catalog.views import ProductViewSet

DEFAULT_CASES = Path(__file__).resolve().parents[2] / "search_eval_cases.json"

_HAMZA_AND_TA = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ة": "ه", "ى": "ي"})
_GLUED = re.compile(r"([ء-ي]+)([0-9]+)")


class Command(BaseCommand):
    help = "Measure whether product search returns the product people meant."

    def add_arguments(self, parser):
        parser.add_argument("--cases", default=str(DEFAULT_CASES))
        parser.add_argument("--synthetic", type=int, default=200)
        parser.add_argument("--seed", type=int, default=7)
        parser.add_argument(
            "--show",
            choices=("misses", "all", "none"),
            default="misses",
            help="which recorded cases to list one by one",
        )

    def handle(self, *args, **options):
        self.view = ProductViewSet.as_view({"get": "list"})
        self.factory = APIRequestFactory()
        self.user = get_user_model()(username="search-eval", is_superuser=True, is_staff=True)
        self.timings = []

        recorded = self._recorded(Path(options["cases"]), options["show"])
        generated = self._generated(options["synthetic"], options["seed"])

        self.stdout.write("")
        self.stdout.write(
            f"{'kind':44s} {'n':>5s} {'@1':>7s} {'@5':>7s} {'@10':>7s} {'page':>7s}"
        )
        for kind, ranks in [*recorded.items(), *generated.items()]:
            self.stdout.write(self._row(kind, ranks))
        if self.timings:
            ordered = sorted(self.timings)
            p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
            self.stdout.write(
                f"\n{len(ordered)} searches, median {statistics.median(ordered):.0f} ms,"
                f" p95 {p95:.0f} ms, max {ordered[-1]:.0f} ms (list view incl. serializer)"
            )

    # -- running one search ---------------------------------------------------

    def _search(self, query):
        request = self.factory.get(
            "/api/products/",
            {
                "search": query,
                "is_active": "true",
                "system": "sellable",
                "ordering": "-popularity",
            },
            # Pagination builds absolute links; every deployment allows localhost.
            HTTP_HOST="localhost",
        )
        force_authenticate(request, user=self.user)
        started = time.perf_counter()
        response = self.view(request)
        response.render()
        self.timings.append((time.perf_counter() - started) * 1000)
        if response.status_code != 200:
            raise CommandError(f"search {query!r} answered {response.status_code}")
        rows = response.data.get("results", [])
        outcome = response.data.get("search") or {}
        return rows, outcome.get("match", "")

    @staticmethod
    def _rank(rows, predicate):
        for index, row in enumerate(rows, start=1):
            if predicate(row):
                return index
        return None

    @staticmethod
    def _row(kind, ranks):
        total = len(ranks)
        if not total:
            return f"{kind:44s} {0:5d}"

        def share(k):
            return 100 * sum(1 for rank in ranks if rank is not None and rank <= k) / total

        return (
            f"{kind:44s} {total:5d} {share(1):6.1f}% {share(5):6.1f}%"
            f" {share(10):6.1f}% {share(50):6.1f}%"
        )

    # -- recorded cases -----------------------------------------------------------

    def _recorded(self, path, show):
        if not path.exists():
            raise CommandError(f"no cases file at {path}")
        cases = json.loads(path.read_text(encoding="utf-8"))
        names = list(
            Product.objects.filter(archived_at__isnull=True).values_list("search_name", flat=True)
        )
        ranks, skipped = [], []
        for case in cases:
            expected = case["expect"] if isinstance(case["expect"], list) else [case["expect"]]
            wanted = [search_text.fold(text) for text in expected]
            if not any(fragment in name for name in names for fragment in wanted):
                skipped.append(case["query"])
                continue
            rows, match = self._search(case["query"])
            rank = self._rank(
                rows,
                lambda row: any(fragment in search_text.fold(row["name"]) for fragment in wanted),
            )
            ranks.append(rank)
            if show == "all" or (show == "misses" and (rank is None or rank > 5)):
                top = rows[0]["name"] if rows else "—"
                self.stdout.write(
                    f"  {case['query']!r:28} -> {expected[0]!r:22} rank {rank or '-':>3}"
                    f"  [{match}]  top: {top}"
                )
        if skipped:
            self.stdout.write(f"  skipped (not in this catalogue): {', '.join(skipped)}")
        return {"recorded: what cashiers typed": ranks}

    # -- generated cases ----------------------------------------------------------

    def _generated(self, count, seed):
        if count <= 0:
            return {}
        candidates = list(
            Product.objects.filter(archived_at__isnull=True, is_active=True)
            .order_by("id")
            .values_list("id", "name")
        )
        candidates = [(pk, name) for pk, name in candidates if len(name.split()) >= 3]
        picked = random.Random(seed).sample(candidates, min(count, len(candidates)))
        shapes = {
            "generated: two words, reversed": [],
            "generated: first + last word": [],
            "generated: no hamza, ه for ة": [],
            "generated: glued size typed apart": [],
        }
        for pk, name in picked:
            words = name.split()
            queries = {
                "generated: two words, reversed": f"{words[1]} {words[0]}",
                "generated: first + last word": f"{words[0]} {words[-1]}",
            }
            plain = f"{words[0]} {words[1]}".translate(_HAMZA_AND_TA)
            if plain != f"{words[0]} {words[1]}":
                queries["generated: no hamza, ه for ة"] = plain
            glued = _GLUED.search(name)
            if glued:
                queries["generated: glued size typed apart"] = f"{glued.group(1)} {glued.group(2)}"
            for shape, query in queries.items():
                rows, _match = self._search(query)
                shapes[shape].append(self._rank(rows, lambda row, pk=pk: row["id"] == pk))
        return shapes
