"""The planning pass — settle the catalogue's codes before anything is written.

An import's catalogue loads on parallel workers (``engine``). A unique index
stops two of them writing the same SKU, but it cannot stop one barcode ringing
up two things across tables — a variant's own barcode, an extra barcode and a
packaging barcode are separate columns, and the loaders keep "one code, one
thing" by looking before they write. Two workers can both look, both see the
code free, and both write it.

So before any worker starts, this pass walks the file in the order a serial
run would load it and gives every code to the first product that claims it.
A later claim by a *different* product is dropped from that record, with the
same kind of warning a conflict with the shop's existing catalogue gets. After
that, no two workers can ever reach for the same code: a product's records all
go to one worker, and no two products share a code. The unique indexes stay as
the last word for anything this pass did not foresee.

The pass also numbers the variants that will need an automatic SKU — a blank
one, or one dropped as a duplicate — from one block claimed up front
(``sku_series.reserve_variant_skus``), instead of each worker taking the
allocation lock until its batch commits.

The dry run applies the same plan, so a preview still counts exactly what the
import will do.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from apps.catalog.models import normalize_barcode, normalize_sku

from .entity_plan import PRODUCT, PRODUCT_UNIT, PURCHASE_ORDER, SALE, SUPPLIER, VARIANT
from .loaders.base import WARNING, Issue, clean_str

#: The entities the plan reads (and may change) before the run loads them.
PLANNED = (PRODUCT, VARIANT, PRODUCT_UNIT)

# A shop's own serial — the codes ``sku_series`` counts past.
_SERIES_CODE = re.compile(r"^[0-9]{1,7}$")


@dataclass
class CatalogPlan:
    #: (entity_type, issue) for every code the plan dropped.
    issues: list[tuple[str, Issue]] = field(default_factory=list)
    #: Highest plain-number code anywhere in the file, which the generated
    #: block must start past.
    floor: int | None = None
    #: Records that take an automatic SKU, in load order.
    numbered: list = field(default_factory=list)

    def number_from(self, start: int) -> None:
        for offset, record in enumerate(self.numbered):
            record.sku = str(start + offset)


def plan_catalog(records: dict[str, list], resolver) -> CatalogPlan:
    plan = CatalogPlan()
    barcodes: dict[str, str] = {}
    skus: dict[str, str] = {}

    def floor(code):
        if _SERIES_CODE.match(code):
            plan.floor = max(plan.floor or 0, int(code))

    def claim(owners, code, owner) -> bool:
        holder = owners.setdefault(code, owner)
        return holder == owner

    def dropped_barcode(entity, record, code):
        plan.issues.append(
            (
                entity,
                Issue(
                    WARNING,
                    "duplicate_code_in_file",
                    f"الباركود {code!r} مكرر في الملف لصنف آخر — بقي مع أول صنف ورد عليه.",
                    source_key=str(record.source_key),
                ),
            )
        )

    def settle_barcodes(entity, record, owner, codes):
        kept = []
        for raw in codes or []:
            code = normalize_barcode(clean_str(raw))
            if not code:
                continue
            floor(code)
            if claim(barcodes, code, owner):
                kept.append(raw)
            else:
                dropped_barcode(entity, record, code)
        return kept

    def settle_sku(entity, record, owner) -> bool:
        """Keep the record's SKU if it is its own; False when it was dropped."""
        sku = normalize_sku(record.sku)
        if not sku:
            return True
        floor(sku)
        if claim(skus, sku, owner):
            return True
        record.sku = ""
        plan.issues.append(
            (
                entity,
                Issue(
                    WARNING,
                    "duplicate_code_in_file",
                    f"رمز الصنف {sku!r} مكرر في الملف لصنف آخر — أُعطي هذا الصنف رمزًا جديدًا.",
                    source_key=str(record.source_key),
                ),
            )
        )
        return False

    def settle_primary(entity, record, owner):
        code = normalize_barcode(record.barcode)
        if not code:
            return
        floor(code)
        if not claim(barcodes, code, owner):
            record.barcode = ""
            dropped_barcode(entity, record, code)

    for record in records.get(PRODUCT, ()):
        owner = str(record.source_key)
        makes_variant = bool(
            record.unit_price is not None
            or record.sku
            or record.barcode
            or getattr(record, "extra_barcodes", None)
        )
        settle_sku(PRODUCT, record, owner)
        settle_primary(PRODUCT, record, owner)
        record.extra_barcodes = settle_barcodes(
            PRODUCT, record, owner, getattr(record, "extra_barcodes", None)
        )
        # A product the shop already has keeps the code it carries; only a new
        # one is numbered (the same rule ``_default_variant_defaults`` keeps).
        if (
            makes_variant
            and not normalize_sku(record.sku)
            and resolver.resolve(PRODUCT, record.source_key) is None
        ):
            plan.numbered.append(record)

    for record in records.get(VARIANT, ()):
        owner = str(record.product_source_key)
        if not settle_sku(VARIANT, record, owner):
            # A variant must carry a SKU; one that lost a duplicate takes a new one.
            plan.numbered.append(record)
        settle_primary(VARIANT, record, owner)
        record.extra_barcodes = settle_barcodes(
            VARIANT, record, owner, getattr(record, "extra_barcodes", None)
        )

    for record in records.get(PRODUCT_UNIT, ()):
        owner = str(record.product_source_key)
        record.barcodes = settle_barcodes(PRODUCT_UNIT, record, owner, record.barcodes)

    return plan


# --- documents ------------------------------------------------------------
#
# Invoices and purchase orders load on parallel workers too, and two things
# they share would race there. A carried receipt number is checked before it
# is written, so two workers can both find one free; and a document numbered
# from the shop's own series takes that counter's row lock until its batch
# commits, which would line the workers up behind each other.
#
# So numbers are settled as the records stream past, in file order: a carried
# number goes to the first invoice that has it and is free in the shop, and
# everything else is written under a placeholder and numbered afterwards —
# all at once, in file order, from one move of the counter
# (``renumber_placeholders``). The counter moves by exactly the documents that
# were written, so a record that fails leaves no hole in the series.

#: Marks a document number the renumbering pass has yet to give. Nothing else
#: in the shop starts a number with it.
PLACEHOLDER_PREFIX = "~"


def placeholder_number(run_pk: int, seq: int) -> str:
    return f"{PLACEHOLDER_PREFIX}{run_pk}{PLACEHOLDER_PREFIX}{seq}"


class DocumentPlanner:
    """Settles one document entity's numbers, a chunk at a time, in file order."""

    def __init__(self, entity_type: str, resolver, run):
        self.entity_type = entity_type
        self.resolver = resolver
        self.run = run
        self._seq = 0
        self._carried: set[str] = set()
        self._fallback_supplier_ready = False

    def _next_placeholder(self) -> str:
        self._seq += 1
        return placeholder_number(self.run.pk, self._seq)

    def prepare(self, chunk) -> list[tuple[str, Issue]]:
        new = [r for r in chunk if self.resolver.resolve(self.entity_type, r.source_key) is None]
        if self.entity_type == SALE:
            return self._prepare_sales(new)
        self._prepare_purchases(chunk, new)
        return []

    def _prepare_sales(self, records) -> list[tuple[str, Issue]]:
        from apps.sales.models import Order

        issues = []
        wanted = {
            id(record): str(record.receipt_number or "").strip()[:32] for record in records
        }
        taken = set(
            Order.objects.filter(
                receipt_number__in=[number for number in wanted.values() if number]
            ).values_list("receipt_number", flat=True)
        )
        for record in records:
            number = wanted[id(record)]
            if number and number not in taken and number not in self._carried:
                self._carried.add(number)
                record.receipt_number = number
                continue
            if number:
                # The same words the loader uses for a number the shop has.
                issues.append(
                    (
                        SALE,
                        Issue(
                            WARNING,
                            "receipt_number_taken",
                            f"رقم الفاتورة {number!r} مستخدم من قبل — أُعطيت الفاتورة رقمًا جديدًا.",
                            source_key=str(record.source_key),
                        ),
                    )
                )
            record.receipt_number = self._next_placeholder()
        return issues

    def _prepare_purchases(self, chunk, new) -> None:
        for record in new:
            record.planned_number = self._next_placeholder()
        if not self._fallback_supplier_ready and any(
            self.resolver.resolve(SUPPLIER, record.supplier_source_key) is None
            for record in chunk
        ):
            # An order with no known supplier is filed under one stand-in
            # supplier; made here, once, so two workers cannot both make it.
            from .loaders.purchasing import fallback_supplier

            fallback_supplier()
            self._fallback_supplier_ready = True


def document_planner(entity_type: str, resolver, run) -> DocumentPlanner | None:
    if entity_type in (SALE, PURCHASE_ORDER):
        return DocumentPlanner(entity_type, resolver, run)
    return None


def renumber_placeholders(entity_type: str) -> int:
    """Give every placeholder-numbered document its real number; returns how many.

    In file order — a run's placeholders count up as its records streamed —
    and from one move of the counter. Any run's leftovers are taken too, so an
    import that died before getting here is put right by the next one.
    """
    from django.db import transaction
    from django.utils import timezone

    from apps.documents.guards import system_write
    from apps.documents.numbering import (
        PURCHASE_ORDER_SERIES,
        SALE_ORDER_SERIES,
        reserve_document_numbers,
    )
    from apps.purchasing.models import PurchaseOrder
    from apps.sales.models import Order

    model, field_name, series, letter = {
        SALE: (Order, "receipt_number", SALE_ORDER_SERIES, "R"),
        PURCHASE_ORDER: (PurchaseOrder, "order_number", PURCHASE_ORDER_SERIES, "P"),
    }[entity_type]

    def order(row):
        _, run_pk, seq = row[1].split(PLACEHOLDER_PREFIX)
        return int(run_pk), int(seq)

    with transaction.atomic():
        rows = sorted(
            model.objects.filter(**{f"{field_name}__startswith": PLACEHOLDER_PREFIX})
            .select_for_update()
            .values_list("pk", field_name),
            key=order,
        )
        if not rows:
            return 0
        first = reserve_document_numbers(series, len(rows))
        issued = timezone.now()
        documents = [
            model(pk=pk, **{field_name: f"{letter}{issued:%Y%m%d}{first + offset:06d}"})
            for offset, (pk, _placeholder) in enumerate(rows)
        ]
        # The import's own documents, finished the way a serial run would have
        # numbered them — the machine completing its write, not a person
        # editing an issued document.
        with system_write():
            model.objects.bulk_update(documents, [field_name], batch_size=500)
    return len(rows)
