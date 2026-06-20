"""Sales loaders: sales (+lines) and payments.

Stubs this pass. When a real dump arrives, implement these with **direct ORM
writes** — do NOT route through ``apps.sales.services.create_order_with_lines``,
which applies discounts, creates live stock movements, and recalculates totals
(all wrong for a historical import). Resolve ``customer_source_key`` /
``variant_source_key`` through the resolver, write ``Order``/``OrderLine`` rows
directly, set ``receipt_number`` from source if present, then ``remember`` the
order so its payments can resolve it.
"""

from __future__ import annotations

from ..entity_plan import PAYMENT, SALE
from .base import NotImplementedLoader


class SaleLoader(NotImplementedLoader):
    entity_type = SALE


class PaymentLoader(NotImplementedLoader):
    entity_type = PAYMENT
