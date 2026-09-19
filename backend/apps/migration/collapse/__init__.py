"""The "collapse serialized products" migration step (§12).

A used-phone shop whose old POS had products and sub-barcodes and nothing else
worked around it the only way that system allowed: one product per physical
handset. Four years later that is 340 products which are really 340 *units* of
a dozen products, and it breaks every derived number a POS computes — nothing
aggregates, valuation degenerates, and the identity that matters most in the
trade is untyped text inside a name (§1.2).

This package is what converts that catalogue back into stock:

* :mod:`~apps.migration.collapse.extract` reads one legacy name apart,
* :mod:`~apps.migration.collapse.planner` clusters, prices and counts the whole
  file into a proposal nobody has agreed to yet,
* :mod:`~apps.migration.collapse.apply` turns an approved proposal into
  products, variants, identified articles and a shelf — inside the ordinary
  import, so four years of invoices land on the collapsed rows with no second
  definition of what a legacy key means.

Nothing is written until the owner approves, anything unparseable stays a
product, and the §5.4 invariants are run over the result before it commits.
"""

from .apply import CollapseSession
from .extract import Extraction, extract_name
from .planner import build_plan, clusters_for, recompute_stats

#: ``extract`` is deliberately **not** re-exported: it is the name of a
#: submodule of this package, and binding it to the function here makes
#: ``from . import extract`` return the function to whichever module imports the
#: package second. :func:`extract_name` is the same function under a name that
#: cannot be mistaken for a module.
__all__ = [
    "CollapseSession",
    "Extraction",
    "build_plan",
    "clusters_for",
    "extract_name",
    "recompute_stats",
]
