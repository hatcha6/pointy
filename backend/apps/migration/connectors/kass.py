"""KASS connector — the Delphi/MySQL POS used by phone shops in Libya.

The vendor does not name itself anywhere in its own data; the database is called
``KASS<year>`` and the tables are Arabic words transliterated into ASCII
(``kamkrt`` = كرت الصنف, the item card; ``kamhrka`` = حركة, a document;
``edaahrka``, the cash movements). The schema signature is therefore the
identity, which is what :class:`VersionSpec` matching is for.

Shops hand over a **SQL text dump** — the vendor's own "backup" button — which
``preparation/mysqldump.py`` replays into SQLite before any of this runs.

Shape of the source
-------------------
``kamhrka`` is one table of documents discriminated by ``EthenType``, with its
lines in ``kammwad`` under the same key:

* ``1`` — purchase          → purchase orders
* ``3`` — sales return      → returns (see below)
* ``7`` — sale              → sales

``edaahrka`` is one table of money movements discriminated by ``SrfOREstlam``:

* ``21`` — قبض, money in     → receipts against a customer's account
* ``22`` — صرف, money out    → supplier payments
* ``29`` — the daily cash sweep (deliberately not imported — see below)
* ``31`` — the cash box's opening balance
* ``33`` — an expense, carrying its category in ``MasrofNo``

``amilkrt`` is **one** party table: customers and suppliers share an account, and
the ``AmilPuy``/``AmilSell`` flags are both 1 on every row in the field data, so
they say nothing. Who a party is, is decided by what they did.

Things in here that were established from the data rather than assumed
-------------------------------------------------------------------
**``Price`` is empty on every line; the price is ``PriceWithOut``.** All 3,837
lines in the reference dump carry ``Price = 0``. Reading the obvious column
imports a shop's entire history at zero and reports no error at all.

**``PuyKetaey`` is the selling price and ``NawPrice`` is the cost**, despite
"Puy" reading like "buy". Confirmed two ways: ``NawPrice`` equals the cost
stamped on sale lines for 519 of 529 products, and the POS's own audit log
prints "تم إضافة لصقة بسعر 15.000" for the product whose ``PuyKetaey`` is 15.

**``EthenType = 3`` adds stock, so it is a *sales return*, not a second sale.**
Netting each product's movements against the item card's closing balance only
reconciles when type 3 is an inflow (e.g. product 601: 0 + 0 − 5 + 1 = −4, which
is exactly its stored balance).

**The party balance is one signed account**: ``NawRasid = FirstRasid +
purchases − payments out − sales + returns + receipts``, positive meaning the
shop owes them. That identity holds exactly for all 22 parties with any
activity, which is what makes the opening balances below trustworthy.

Choices worth knowing about
---------------------------
**Opening balances become documents.** Pointy derives what is owed from open
invoices, so a party whose debt predates the file's history has nothing to hang
it on — five customers here have a balance and not one invoice. They would
import at zero and the shop would lose the money. Each gets one dated document
against a service product named "رصيد افتتاحي", which carries no stock and no
cost, and which the shop can settle through the ordinary payments screen.

**The daily cash sweep (``29``) is not imported.** Those 158 rows are that day's
takings moved into the box, and they equal the day's cash sales to the dinar.
Pointy's money position already derives cash from the sales themselves
(``apps.treasury.position``), so posting the sweep as well would state the same
71,751 dinars twice. Only the opening balance (``31``) is carried.

**A return against an unpaid آجل invoice is netted into that invoice** instead
of being written as a refund. Pointy represents a refund as a negative payment,
which is right when cash went back across the counter, but on an invoice that
was never paid it would *raise* the balance rather than lower it. Goods handed
back against a debt reduce the debt, so the invoice is imported at what was
finally owed.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterator
from datetime import date, datetime, timedelta
from decimal import Decimal

from .. import canonical
from ..entity_plan import (
    CATEGORY,
    CUSTOMER,
    EMPLOYEE,
    EXPENSE,
    EXPENSE_CATEGORY,
    MONEY_ACCOUNT,
    PARTY_BALANCE,
    PAYMENT,
    PAYROLL_RUN,
    PRODUCT,
    PURCHASE_ORDER,
    SALE,
    SALE_RETURN,
    STOCK,
    SUPPLIER,
    SUPPLIER_PAYMENT,
    UNIT,
)
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec
from .values import (
    clean as _clean,
    lower_keys as _lower,
    parse_datetime as _parse_dt,
    to_decimal as _to_decimal,
    to_int as _to_int,
)

# Document types in ``kamhrka.EthenType`` / ``kammwad.EthenType``.
DOC_PURCHASE = 1
DOC_SALE_RETURN = 3
DOC_SALE = 7

# Money movement kinds in ``edaahrka.SrfOREstlam``.
CASH_RECEIPT = 21
CASH_PAYMENT = 22
CASH_SWEEP = 29
CASH_OPENING = 31
CASH_EXPENSE = 33

# ``kamhrka.SdadType``: 1 = آجل (on the party's account), 2 = paid now.
SETTLE_CREDIT = 1

ZERO = Decimal("0")
_MONEY = Decimal("0.01")

#: Parties that are not people. A Delphi POS books every walk-in sale against a
#: standing "cash sales" account so the day's takings have somewhere to land;
#: importing it would create a customer with 2,646 invoices and a running
#: balance that is really the shop's own till.
_PLACEHOLDER_PARTIES = {
    "مبيعات نقدية",
    "مبيعات نقديه",
    "مشتريات عامة",
    "مشتريات عامه",
    "زبون نقدي",
    "نقدي",
}

#: The service product opening balances are written against.
OPENING_PRODUCT_KEY = "opening-balance"
OPENING_PRODUCT_NAME = "رصيد افتتاحي"

_DEFAULT_UNIT_NAME = "قطعة"


def _norm(name: str) -> str:
    """Arabic text as a comparison key: collapsed spaces, no tatweel."""
    return " ".join(_clean(name).replace("ـ", "").split())


class KassConnector(BaseConnector):
    system_key = "kass"
    display_name = "نظام كاس (دلفي)"
    implemented = True
    required_transport = "sqlite"
    # kamkrt.NawRasid is the item card's on-hand quantity.
    supports_stock_filter = True
    supported_entities = (
        UNIT,
        CATEGORY,
        PRODUCT,
        STOCK,
        CUSTOMER,
        SUPPLIER,
        PARTY_BALANCE,
        PURCHASE_ORDER,
        SUPPLIER_PAYMENT,
        SALE,
        SALE_RETURN,
        PAYMENT,
        EMPLOYEE,
        PAYROLL_RUN,
        EXPENSE_CATEGORY,
        EXPENSE,
        MONEY_ACCOUNT,
    )
    analysis_tables = {
        PRODUCT: ("kamkrt", None),
        CUSTOMER: ("amilkrt", None),
        SALE: ("kamhrka", "date1"),
        EXPENSE: ("edaahrka", "Date1"),
        EMPLOYEE: ("aamldata", None),
    }
    versions = (
        VersionSpec(
            version_key="kass-delphi-mysql",
            required_tables=(
                RequiredTable(
                    "kamkrt",
                    ("SenfNo", "SenfDisc", "Barcode", "NawRasid", "NawPrice", "PuyKetaey"),
                ),
                RequiredTable(
                    "kamhrka",
                    ("EthenNo", "EthenType", "AmilNo", "date1", "AsnafTotal", "SdadType"),
                ),
                RequiredTable(
                    "kammwad",
                    ("EthenNo", "EthenType", "SenfNo", "Quilty", "PriceWithOut", "Taklofa"),
                ),
                RequiredTable("amilkrt", ("AmilNo", "AmilName", "NawRasid", "FirstRasid")),
                RequiredTable(
                    "edaahrka",
                    ("SrfEthenNo", "SrfOREstlam", "AmilNo", "Date1", "Price"),
                ),
                RequiredTable("groups", ("GroupNo", "GroupName")),
                RequiredTable("company", ("CompanyNo", "CompanyName")),
                RequiredTable("msrftype", ("MsrofNo", "MsrofName")),
            ),
        ),
    )

    # --- dispatch --------------------------------------------------------
    def extract(self, entity_type: str, transport, ctx: ExtractContext) -> Iterator:
        handlers = {
            UNIT: self._units,
            CATEGORY: self._categories,
            PRODUCT: self._products,
            STOCK: self._stock,
            CUSTOMER: self._customers,
            SUPPLIER: self._suppliers,
            PARTY_BALANCE: self._party_balances,
            PURCHASE_ORDER: self._purchase_orders,
            SUPPLIER_PAYMENT: self._supplier_payments,
            SALE: self._sales,
            SALE_RETURN: self._sale_returns,
            PAYMENT: self._receipts,
            EMPLOYEE: self._employees,
            PAYROLL_RUN: self._payroll_runs,
            EXPENSE_CATEGORY: self._expense_categories,
            EXPENSE: self._expenses,
            MONEY_ACCOUNT: self._money_accounts,
        }
        handler = handlers.get(entity_type)
        if handler is not None:
            yield from handler(transport, ctx)

    # --- catalogue -------------------------------------------------------
    def _units(self, transport, ctx):
        seen = set()
        for row in transport.iter_records("kamkrt", fields=["Unit"]):
            name = _clean(_lower(row).get("unit"))
            # "." is a keyboard slip that made it into a live item card.
            if not name or name == "." or name in seen:
                continue
            seen.add(name)
            yield canonical.CanonicalUnit(
                source_key=f"unit:{name}",
                code=name[:16],
                name=name,
                abbreviation=name[:8],
                dimension="count",
                allows_fractional=False,
            )
        if _DEFAULT_UNIT_NAME not in seen:
            yield canonical.CanonicalUnit(
                source_key=f"unit:{_DEFAULT_UNIT_NAME}",
                code=_DEFAULT_UNIT_NAME,
                name=_DEFAULT_UNIT_NAME,
                abbreviation=_DEFAULT_UNIT_NAME,
                dimension="count",
            )

    def _categories(self, transport, ctx):
        """Both of the source's classification axes.

        ``groups`` and ``company`` are independent — a product carries one of
        each — so both become flat Pointy categories and a product is filed
        under both, the same way the AboGhris connector treats its two.
        """
        for row in transport.iter_records("groups"):
            record = _lower(row)
            number = _to_int(record.get("groupno"))
            name = _clean(record.get("groupname"))
            if number is None or not name:
                continue
            yield canonical.CanonicalCategory(
                source_key=f"group:{number}", name=name, raw=record
            )
        for row in transport.iter_records("company"):
            record = _lower(row)
            number = _to_int(record.get("companyno"))
            name = _clean(record.get("companyname"))
            if number is None or not name:
                continue
            yield canonical.CanonicalCategory(
                source_key=f"company:{number}", name=name, raw=record
            )

    def _products(self, transport, ctx):
        """One product per item card, plus the opening-balance service item.

        The card's own ``Barcode`` is a four-digit internal code the shop prints
        its own labels with, not an EAN — it is still what gets scanned at the
        counter, so it is carried as both the barcode and the SKU.
        """
        for row in transport.iter_records("kamkrt"):
            record = _lower(row)
            item = _to_int(record.get("senfno"))
            name = _clean(record.get("senfdisc"))
            if item is None or not name:
                continue
            if ctx.only_stocked_products and _to_decimal(record.get("nawrasid")) <= ZERO:
                continue
            unit = _clean(record.get("unit"))
            if not unit or unit == ".":
                unit = _DEFAULT_UNIT_NAME
            categories = []
            group = _to_int(record.get("groupno"))
            if group:
                categories.append(f"group:{group}")
            company = _to_int(record.get("companyno"))
            if company:
                categories.append(f"company:{company}")
            barcode = _clean(record.get("barcode"))
            yield canonical.CanonicalProduct(
                source_key=f"item:{item}",
                name=name[:255],
                unit=unit,
                is_active=True,
                category_source_keys=categories,
                sku=barcode[:64],
                barcode=barcode[:64],
                unit_price=_to_decimal(record.get("puyketaey")),
                raw=record,
            )
        yield canonical.CanonicalProduct(
            source_key=OPENING_PRODUCT_KEY,
            name=OPENING_PRODUCT_NAME,
            description=(
                "بند فني يحمل أرصدة العملاء والموردين المرحّلة من النظام السابق. "
                "لا يُباع ولا يُشترى."
            ),
            unit=_DEFAULT_UNIT_NAME,
            # A service keeps no stock and is skipped by the stock loader, so
            # carrying a debt on it can never move inventory or cost of sales.
            is_service=True,
            is_active=True,
            unit_price=ZERO,
        )

    def _stock(self, transport, ctx):
        for row in transport.iter_records("kamkrt"):
            record = _lower(row)
            item = _to_int(record.get("senfno"))
            if item is None:
                continue
            # Mirrors the product filter exactly: a stock row for a product that
            # was never emitted would be an unresolved-variant error per item.
            if ctx.only_stocked_products and _to_decimal(record.get("nawrasid")) <= ZERO:
                continue
            reorder = _to_int(record.get("lessrasid"))
            yield canonical.CanonicalStock(
                source_key=f"item:{item}",
                variant_source_key=f"item:{item}",
                quantity_on_hand=_to_decimal(record.get("nawrasid")),
                reorder_level=reorder if reorder and reorder > 0 else None,
                # The card's moving-average cost, which is what the source's own
                # sale lines are stamped with.
                unit_cost=_to_decimal(record.get("nawprice")),
                raw=record,
            )

    # --- parties ---------------------------------------------------------
    def _parties(self, transport, ctx) -> dict:
        """Every party, with the roles their own documents give them.

        Returns ``{amil_no: {...}}`` carrying the row, whether the party bought,
        sold or is a placeholder, and the opening balance split by side.
        """
        cached = ctx.cache.get("kass_parties")
        if cached is not None:
            return cached

        parties: dict[int, dict] = {}
        for row in transport.iter_records("amilkrt"):
            record = _lower(row)
            number = _to_int(record.get("amilno"))
            if number is None:
                continue
            opening = _to_decimal(record.get("firstrasid"))
            parties[number] = {
                "row": record,
                "name": _clean(record.get("amilname")),
                "is_placeholder": _norm(record.get("amilname")) in _PLACEHOLDER_PARTIES,
                "sold_to": False,
                "bought_from": False,
                # Sign convention proved against every party in the field dump:
                # a positive balance is money the shop owes, a negative one is
                # money it is owed.
                "opening_payable": opening if opening > 0 else ZERO,
                "opening_receivable": -opening if opening < 0 else ZERO,
                "balance": _to_decimal(record.get("nawrasid")),
            }

        for row in transport.raw_query(
            "SELECT AmilNo, CAST(EthenType AS INTEGER) AS t, COUNT(*) AS n "
            "FROM kamhrka GROUP BY AmilNo, t"
        ):
            record = _lower(row)
            number = _to_int(record.get("amilno"))
            party = parties.get(number)
            if party is None:
                continue
            if record.get("t") == DOC_PURCHASE:
                party["bought_from"] = True
            else:
                party["sold_to"] = True

        for row in transport.raw_query(
            "SELECT AmilNo, CAST(SrfOREstlam AS INTEGER) AS k, COUNT(*) AS n "
            "FROM edaahrka GROUP BY AmilNo, k"
        ):
            record = _lower(row)
            number = _to_int(record.get("amilno"))
            party = parties.get(number)
            if party is None:
                continue
            if record.get("k") == CASH_PAYMENT:
                party["bought_from"] = True
            elif record.get("k") == CASH_RECEIPT:
                party["sold_to"] = True

        # A party with a balance and no documents at all still has to land
        # somewhere, or their debt is silently dropped. Both figures are
        # consulted, not just the opening one: a balances-only import reads the
        # *current* balance, and a party who has one of those and no opening
        # would otherwise be given no role and dropped before it was read.
        for party in parties.values():
            if party["is_placeholder"] or party["sold_to"] or party["bought_from"]:
                continue
            if party["opening_payable"] > 0 or party["balance"] > 0:
                party["bought_from"] = True
            elif party["opening_receivable"] > 0 or party["balance"] < 0:
                party["sold_to"] = True

        ctx.cache["kass_parties"] = parties
        return parties

    def _customers(self, transport, ctx):
        for number, party in sorted(self._parties(transport, ctx).items()):
            if party["is_placeholder"] or not party["sold_to"] or not party["name"]:
                continue
            record = party["row"]
            yield canonical.CanonicalCustomer(
                source_key=f"party:{number}",
                full_name=party["name"][:255],
                phone=_clean(record.get("mobile")) or _clean(record.get("phone")),
                email=_clean(record.get("emial")),
                notes=_clean(record.get("notes")),
                is_active=True,
                raw=record,
            )

    def _suppliers(self, transport, ctx):
        for number, party in sorted(self._parties(transport, ctx).items()):
            if party["is_placeholder"] or not party["bought_from"] or not party["name"]:
                continue
            record = party["row"]
            yield canonical.CanonicalSupplier(
                source_key=f"party:{number}",
                name=party["name"][:255],
                phone=_clean(record.get("mobile")) or _clean(record.get("phone")),
                email=_clean(record.get("emial")),
                notes=_clean(record.get("notes")),
                is_active=True,
                raw=record,
            )

    # --- documents -------------------------------------------------------
    def _headers(self, transport, ctx, doc_type: int) -> list[dict]:
        cache_key = f"kass_headers:{doc_type}"
        cached = ctx.cache.get(cache_key)
        if cached is not None:
            return cached
        rows = [
            _lower(row)
            for row in transport.raw_query(
                "SELECT * FROM kamhrka WHERE CAST(EthenType AS INTEGER) = ? "
                "ORDER BY date1, EnteredDate, EthenNoParty",
                [doc_type],
            )
        ]
        ctx.cache[cache_key] = rows
        return rows

    def _lines(self, transport, ctx, doc_type: int) -> dict[str, list[dict]]:
        cache_key = f"kass_lines:{doc_type}"
        cached = ctx.cache.get(cache_key)
        if cached is not None:
            return cached
        grouped: dict[str, list[dict]] = defaultdict(list)
        for row in transport.raw_query(
            "SELECT * FROM kammwad WHERE CAST(EthenType AS INTEGER) = ? "
            "ORDER BY COUNTER",
            [doc_type],
        ):
            record = _lower(row)
            grouped[_clean(record.get("ethenno"))].append(record)
        ctx.cache[cache_key] = grouped
        return grouped

    @staticmethod
    def _occurred(record) -> datetime | None:
        """The document's moment: its business date, at the clock time it was
        entered when the two agree.

        ``EnteredDate`` carries a real timestamp but drifts onto the next or
        previous day on 306 of 2,892 documents — a sale rung up after midnight,
        or a back-dated one. ``date1`` is the day the shop books it under, and
        moving a sale to a different day would move it to a different Z-Report
        and a different day's takings, so ``date1`` wins and only the
        time-of-day is borrowed.
        """
        business = _parse_dt(record.get("date1"))
        entered = _parse_dt(record.get("entereddate"))
        if business is None:
            return entered
        if entered is not None and entered.date() == business.date():
            return entered
        return business

    def _counter_payments(self, transport, ctx) -> dict:
        """Which invoices were settled at the counter, and for how much.

        This POS posts **every** sale to the party's account and then, for one
        paid on the spot, writes a receipt citing the invoice number
        (``edaahrka.FatoraNo`` → ``kamhrka.EthenNoParty``). So the receipt is
        what says a sale was paid, not ``SdadType``: one shop in the field data
        has a ``SdadType = 2`` invoice for 600 that was settled eight days later
        by an account payment, and trusting the flag books it as cash the shop
        never had and wipes 600 off what the customer owed.

        Returns ``{"paid": {invoice_no: amount}, "linked": {receipt_no, …}}`` —
        the second so those receipts are not *also* imported as account
        payments, which would pay every cash sale twice.
        """
        cached = ctx.cache.get("kass_counter_payments")
        if cached is not None:
            return cached
        invoices = {
            _clean(header.get("ethennoparty")): _to_int(header.get("amilno"))
            for header in self._headers(transport, ctx, DOC_SALE)
        }
        invoices.pop("", None)
        paid: dict[str, Decimal] = defaultdict(Decimal)
        linked: set[str] = set()
        for record in self._cash_rows(transport, ctx, CASH_RECEIPT):
            invoice = _clean(record.get("fatorano"))
            if not invoice or invoice not in invoices:
                continue
            # A receipt credits the account it names, and only that one. The
            # field data has a 600-dinar sale to a named customer whose counter
            # receipt was booked to the walk-in account instead: their ledger
            # shows it unsettled until they paid the account a week later, and
            # treating the receipt as theirs would both clear a debt they still
            # owed and count the 600 twice on the day they finally paid.
            if invoices[invoice] != _to_int(record.get("amilno")):
                continue
            linked.add(_clean(record.get("srfethenno")))
            amount = _to_decimal(record.get("price"))
            if amount > 0:
                paid[invoice] += amount
        result = {"paid": dict(paid), "linked": linked}
        ctx.cache["kass_counter_payments"] = result
        return result

    def _classify(self, transport, ctx, header) -> tuple[bool, Decimal | None]:
        """``(is_credit, amount_paid)`` for one sale.

        A walk-in sale is always cash: there is nobody to owe it, and the two
        invoices in the field data whose counter receipt disagrees with the
        total by a few dinars are a cashier's slip, not a debt.
        """
        customer = self._party_key(transport, ctx, header)
        if customer is None:
            return False, None
        total = _to_decimal(header.get("asnaftotal")) - _to_decimal(header.get("takfid"))
        paid = self._counter_payments(transport, ctx)["paid"].get(
            _clean(header.get("ethennoparty")), ZERO
        )
        if paid >= total:
            return False, None
        return True, paid

    def _party_key(self, transport, ctx, record) -> str | None:
        """The customer a document belongs to, or ``None`` for a walk-in."""
        number = _to_int(record.get("amilno"))
        party = self._parties(transport, ctx).get(number)
        if party is None or party["is_placeholder"]:
            return None
        return f"party:{number}"

    def _returns_index(self, transport, ctx) -> dict:
        """Match every return document to the sale it came off.

        The source files a return as a standalone document naming only the
        product and the party — never the invoice — but Pointy hangs a return on
        the invoice it reverses. So each return line is matched to that party's
        most recent earlier sale of the same product at the same price, which
        resolves 109 of the 111 lines in the field dump (89 of them on the same
        day the sale was rung up).

        Returns ``{"by_sale": {sale_ethenno: [line, …]}, "unmatched": [...]}``.
        """
        cached = ctx.cache.get("kass_returns")
        if cached is not None:
            return cached

        sale_headers = {
            _clean(header.get("ethenno")): header
            for header in self._headers(transport, ctx, DOC_SALE)
        }
        sale_lines = self._lines(transport, ctx, DOC_SALE)
        # (party, product, price) -> [(date, sale_ethenno, line), …] newest last
        index: dict[tuple, list] = defaultdict(list)
        for ethenno, lines in sale_lines.items():
            header = sale_headers.get(ethenno)
            if header is None:
                continue
            party = _to_int(header.get("amilno"))
            when = _parse_dt(header.get("date1"))
            for line in lines:
                key = (
                    party,
                    _to_int(line.get("senfno")),
                    _to_decimal(line.get("pricewithout")),
                )
                index[key].append((when, ethenno, line))
        for entries in index.values():
            entries.sort(key=lambda entry: (entry[0] or date.min, entry[1]))

        by_sale: dict[str, list] = defaultdict(list)
        unmatched: list[dict] = []
        return_headers = self._headers(transport, ctx, DOC_SALE_RETURN)
        return_lines = self._lines(transport, ctx, DOC_SALE_RETURN)
        for header in return_headers:
            ethenno = _clean(header.get("ethenno"))
            party = _to_int(header.get("amilno"))
            when = _parse_dt(header.get("date1"))
            for line in return_lines.get(ethenno, []):
                key = (
                    party,
                    _to_int(line.get("senfno")),
                    _to_decimal(line.get("pricewithout")),
                )
                candidates = [
                    entry
                    for entry in index.get(key, [])
                    if when is None or entry[0] is None or entry[0] <= when
                ]
                if not candidates:
                    unmatched.append({"header": header, "line": line})
                    continue
                _when, sale_ethenno, _sale_line = candidates[-1]
                by_sale[sale_ethenno].append(
                    {"header": header, "line": line, "return_key": ethenno}
                )

        result = {"by_sale": dict(by_sale), "unmatched": unmatched}
        ctx.cache["kass_returns"] = result
        return result

    def _sales(self, transport, ctx):
        """Sales, then one opening-balance invoice per indebted customer."""
        lines_by_doc = self._lines(transport, ctx, DOC_SALE)
        returns = self._returns_index(transport, ctx)["by_sale"]

        for header in self._headers(transport, ctx, DOC_SALE):
            ethenno = _clean(header.get("ethenno"))
            rows = lines_by_doc.get(ethenno) or []
            if not rows:
                continue
            credit, amount_paid = self._classify(transport, ctx, header)
            # A return against an unpaid آجل invoice reduces the debt; it is
            # netted off here rather than written as a refund (see the module
            # docstring).
            netting = {}
            if credit:
                for entry in returns.get(ethenno, []):
                    item = _to_int(entry["line"].get("senfno"))
                    netting[item] = netting.get(item, ZERO) + _to_decimal(
                        entry["line"].get("quilty")
                    )

            lines = []
            for row in rows:
                item = _to_int(row.get("senfno"))
                quantity = _to_decimal(row.get("quilty"))
                if item is None:
                    continue
                if netting:
                    taken = min(netting.get(item, ZERO), quantity)
                    if taken > 0:
                        quantity -= taken
                        netting[item] -= taken
                if quantity <= 0:
                    continue
                lines.append(
                    canonical.CanonicalSaleLine(
                        variant_source_key=f"item:{item}",
                        quantity=quantity,
                        # Never ``Price``: it is zero on every line in the
                        # source. See the module docstring.
                        unit_price=_to_decimal(row.get("pricewithout")),
                        unit_cost=_to_decimal(row.get("taklofa")),
                    )
                )
            if not lines:
                continue

            yield canonical.CanonicalSale(
                source_key=ethenno,
                customer_source_key=self._party_key(transport, ctx, header),
                receipt_number=_clean(header.get("ethennoparty"))[:32],
                status="open" if credit else "paid",
                sale_type="credit" if credit else "standard",
                # Whatever was taken at the counter, which for an آجل invoice is
                # usually nothing; the rest arrives as account receipts.
                amount_paid=amount_paid,
                discount_total=_to_decimal(header.get("takfid")),
                payment_method="cash",
                occurred_at=self._occurred(header),
                lines=lines,
                raw=header,
            )

        # Only when nothing else is carrying them. When PARTY_BALANCE is in
        # the run it owns every opening document, on both sides, and
        # emitting them here as well would owe each debt twice.
        if not ctx.includes(PARTY_BALANCE):
            yield from self._opening_sales(transport, ctx)

    def _opening_sales(self, transport, ctx):
        """One credit invoice per customer who already owed money."""
        opened_at = self._history_start(transport, ctx)
        for number, party in sorted(self._parties(transport, ctx).items()):
            if party["is_placeholder"] or not party["sold_to"]:
                continue
            amount = party["opening_receivable"]
            if amount <= 0:
                continue
            yield canonical.CanonicalSale(
                source_key=f"opening:party:{number}",
                customer_source_key=f"party:{number}",
                status="open",
                sale_type="credit",
                amount_paid=ZERO,
                payment_method="cash",
                occurred_at=opened_at,
                lines=[
                    canonical.CanonicalSaleLine(
                        variant_source_key=OPENING_PRODUCT_KEY,
                        quantity=Decimal("1"),
                        unit_price=amount.quantize(_MONEY),
                        unit_cost=ZERO,
                    )
                ],
                raw={"opening_balance_for": party["name"]},
            )

    # --- party balances --------------------------------------------------
    def _party_balances(self, transport, ctx):
        """What each party stands at, on the basis this run calls for.

        KASS keeps both figures on the party card: ``FirstRasid`` is what they
        were opened with and ``NawRasid`` is where they stand today, the two
        joined by every document in between

            NawRasid = FirstRasid + purchases − payments_out − sales
                       + returns + receipts

        so which one to carry is decided by whether those documents are coming
        too. ``ctx.party_balance_basis`` is that decision, made once for the run
        (see ``scopes.resolve_party_balance_basis``); reading the wrong one is
        silent and produces a plausible number, which is why it is not guessed
        here.

        The sign convention is the source's own, proved against every party in
        the field dump: a positive balance is money the shop owes, a negative
        one is money it is owed.
        """
        opened_at = self._history_start(transport, ctx)
        current = ctx.party_balance_basis == "current"
        for number, party in sorted(self._parties(transport, ctx).items()):
            # مبيعات نقدية and its kind are counter placeholders, not people;
            # their "balance" is the day's cash takings.
            if party["is_placeholder"]:
                continue
            if current:
                balance = party["balance"]
                payable = balance if balance > 0 else ZERO
                receivable = -balance if balance < 0 else ZERO
            else:
                payable = party["opening_payable"]
                receivable = party["opening_receivable"]

            # A party with nothing owed still gets a record. Silence is not the
            # same as zero: if this shop was first imported on the current basis
            # and is now being re-imported with its history, the opening
            # document raised for that earlier balance has to be *withdrawn*,
            # and the only thing that can withdraw it is a record saying the
            # balance is now zero. Skipping them left خالد owing 120.
            if party["sold_to"]:
                yield canonical.CanonicalPartyBalance(
                    source_key=f"opening:party:{number}",
                    party_kind="customer",
                    party_source_key=f"party:{number}",
                    amount=receivable.quantize(_MONEY),
                    as_of=opened_at,
                    basis=ctx.party_balance_basis,
                    party_name=party["name"],
                    raw=party["row"],
                )
            if party["bought_from"]:
                yield canonical.CanonicalPartyBalance(
                    source_key=f"opening:party:{number}",
                    party_kind="supplier",
                    party_source_key=f"party:{number}",
                    amount=payable.quantize(_MONEY),
                    as_of=opened_at,
                    basis=ctx.party_balance_basis,
                    party_name=party["name"],
                    raw=party["row"],
                )

    def _history_start(self, transport, ctx) -> datetime:
        """The day before the first document — where opening balances sit.

        Dated before the history rather than on the day of the import, so an
        opening debt does not appear to have been incurred this morning and the
        customer's invoice list reads in the order it happened.
        """
        cached = ctx.cache.get("kass_history_start")
        if cached is not None:
            return cached
        earliest = None
        for row in transport.raw_query(
            "SELECT MIN(date1) AS d FROM kamhrka WHERE date1 IS NOT NULL AND date1 != ''"
        ):
            earliest = _parse_dt(_lower(row).get("d"))
        for row in transport.raw_query(
            "SELECT MIN(Date1) AS d FROM edaahrka WHERE CAST(SrfOREstlam AS INTEGER) = ?",
            [CASH_OPENING],
        ):
            opening = _parse_dt(_lower(row).get("d"))
            if opening is not None and (earliest is None or opening < earliest):
                earliest = opening
        result = (earliest or datetime.now()) - timedelta(days=1)
        ctx.cache["kass_history_start"] = result
        return result

    def _sale_returns(self, transport, ctx):
        """Returns against invoices that were paid at the counter.

        Ones matched to an unpaid آجل invoice are absent on purpose: they were
        already netted into that invoice by :meth:`_sales`, and emitting them
        here as well would take the goods back twice.
        """
        sale_headers = {
            _clean(header.get("ethenno")): header
            for header in self._headers(transport, ctx, DOC_SALE)
        }
        grouped: dict[tuple[str, str], list] = defaultdict(list)
        for sale_key, entries in self._returns_index(transport, ctx)["by_sale"].items():
            header = sale_headers.get(sale_key)
            if header is None:
                continue
            credit, _paid = self._classify(transport, ctx, header)
            if credit:
                continue
            for entry in entries:
                grouped[(entry["return_key"], sale_key)].append(entry)

        for (return_key, sale_key), entries in sorted(grouped.items()):
            header = entries[0]["header"]
            lines = []
            for entry in entries:
                item = _to_int(entry["line"].get("senfno"))
                quantity = _to_decimal(entry["line"].get("quilty"))
                if item is None or quantity <= 0:
                    continue
                lines.append(
                    canonical.CanonicalSaleReturnLine(
                        variant_source_key=f"item:{item}",
                        quantity=quantity,
                        unit_price=_to_decimal(entry["line"].get("pricewithout")),
                    )
                )
            if not lines:
                continue
            yield canonical.CanonicalSaleReturn(
                # A return can span two invoices; the key names both so each
                # part stays its own idempotent record.
                source_key=f"return:{return_key}:{sale_key}",
                sale_source_key=sale_key,
                occurred_at=self._occurred(header),
                reason=_clean(header.get("notes")) or "مرتجع مبيعات",
                refund_method="cash",
                lines=lines,
                raw=header,
            )

        # Returns with no sale to come off are emitted anyway, with no invoice,
        # so the loader reports them. Silently dropping them would lose goods
        # and money from the history with nothing to say it happened — and an
        # unmatchable return usually means the original sale predates the file.
        for entry in self._returns_index(transport, ctx)["unmatched"]:
            header = entry["header"]
            item = _to_int(entry["line"].get("senfno"))
            quantity = _to_decimal(entry["line"].get("quilty"))
            if item is None or quantity <= 0:
                continue
            yield canonical.CanonicalSaleReturn(
                source_key=(
                    f"return:{_clean(header.get('ethenno'))}:unmatched:{item}"
                ),
                sale_source_key="",
                occurred_at=self._occurred(header),
                reason=_clean(header.get("notes")) or "مرتجع مبيعات",
                refund_method="cash",
                lines=[
                    canonical.CanonicalSaleReturnLine(
                        variant_source_key=f"item:{item}",
                        quantity=quantity,
                        unit_price=_to_decimal(entry["line"].get("pricewithout")),
                    )
                ],
                raw=header,
            )

    def _purchase_orders(self, transport, ctx):
        lines_by_doc = self._lines(transport, ctx, DOC_PURCHASE)
        for header in self._headers(transport, ctx, DOC_PURCHASE):
            ethenno = _clean(header.get("ethenno"))
            rows = lines_by_doc.get(ethenno) or []
            if not rows:
                # Nine blank documents in the field dump, all zero-valued: a
                # purchase screen opened and abandoned.
                continue
            lines = []
            for row in rows:
                item = _to_int(row.get("senfno"))
                quantity = _to_decimal(row.get("quilty"))
                if item is None or quantity <= 0:
                    continue
                lines.append(
                    canonical.CanonicalPurchaseLine(
                        variant_source_key=f"item:{item}",
                        quantity=quantity,
                        unit_cost=_to_decimal(row.get("pricewithout")),
                    )
                )
            if not lines:
                continue
            supplier = self._party_key(transport, ctx, header)
            yield canonical.CanonicalPurchaseOrder(
                source_key=ethenno,
                supplier_source_key=supplier or "",
                status="received",
                supplier_invoice_number=_clean(header.get("ethennoparty"))[:120],
                discount_total=_to_decimal(header.get("takfid")),
                occurred_at=self._occurred(header),
                lines=lines,
                raw=header,
            )

        if not ctx.includes(PARTY_BALANCE):
            yield from self._opening_purchases(transport, ctx)

    def _opening_purchases(self, transport, ctx):
        """One received, unpaid order per supplier the shop already owed."""
        opened_at = self._history_start(transport, ctx)
        for number, party in sorted(self._parties(transport, ctx).items()):
            if party["is_placeholder"] or not party["bought_from"]:
                continue
            amount = party["opening_payable"]
            if amount <= 0:
                continue
            yield canonical.CanonicalPurchaseOrder(
                source_key=f"opening:party:{number}",
                supplier_source_key=f"party:{number}",
                status="received",
                supplier_invoice_number="رصيد افتتاحي",
                occurred_at=opened_at,
                lines=[
                    canonical.CanonicalPurchaseLine(
                        variant_source_key=OPENING_PRODUCT_KEY,
                        quantity=Decimal("1"),
                        unit_cost=amount.quantize(_MONEY),
                    )
                ],
                raw={"opening_balance_for": party["name"]},
            )

    # --- money -----------------------------------------------------------
    def _cash_rows(self, transport, ctx, kind: int) -> list[dict]:
        cache_key = f"kass_cash:{kind}"
        cached = ctx.cache.get(cache_key)
        if cached is not None:
            return cached
        rows = [
            _lower(row)
            for row in transport.raw_query(
                "SELECT * FROM edaahrka WHERE CAST(SrfOREstlam AS INTEGER) = ? "
                "ORDER BY Date1, SrfEthenNo",
                [kind],
            )
        ]
        ctx.cache[cache_key] = rows
        return rows

    def _supplier_payments(self, transport, ctx):
        parties = self._parties(transport, ctx)
        for record in self._cash_rows(transport, ctx, CASH_PAYMENT):
            number = _to_int(record.get("amilno"))
            party = parties.get(number)
            amount = _to_decimal(record.get("price"))
            if party is None or party["is_placeholder"] or amount <= 0:
                # Payments against the walk-in account are the cash handed back
                # on a return; the return document already accounts for those.
                continue
            if not party["bought_from"]:
                continue
            yield canonical.CanonicalSupplierPayment(
                source_key=f"supplier-payment:{_clean(record.get('srfethenno'))}",
                supplier_source_key=f"party:{number}",
                amount=amount,
                method="cash",
                reference=_clean(record.get("eysaldaftar"))[:128],
                notes=_clean(record.get("notes")),
                occurred_at=_parse_dt(record.get("date1")),
                raw=record,
            )

    def _receipts(self, transport, ctx):
        """Money taken in against a customer's account.

        A receipt that cites an invoice number is that invoice's own counter
        payment and was already imported with the sale; importing it again here
        would pay every cash sale twice. Only receipts posted to the account —
        the ones that cite no invoice — are money arriving after the fact.
        """
        parties = self._parties(transport, ctx)
        linked = self._counter_payments(transport, ctx)["linked"]
        for record in self._cash_rows(transport, ctx, CASH_RECEIPT):
            number = _to_int(record.get("amilno"))
            party = parties.get(number)
            amount = _to_decimal(record.get("price"))
            if party is None or party["is_placeholder"] or amount <= 0:
                continue
            if not party["sold_to"]:
                continue
            if _clean(record.get("srfethenno")) in linked:
                continue
            yield canonical.CanonicalPayment(
                source_key=f"receipt:{_clean(record.get('srfethenno'))}",
                customer_source_key=f"party:{number}",
                method="cash",
                amount=amount,
                occurred_at=_parse_dt(record.get("date1")),
                reference=f"kass:receipt:{_clean(record.get('srfethenno'))}"[:128],
                raw=record,
            )

    def _expense_categories(self, transport, ctx):
        for row in transport.iter_records("msrftype"):
            record = _lower(row)
            number = _to_int(record.get("msrofno"))
            name = _clean(record.get("msrofname"))
            if number is None or not name:
                continue
            yield canonical.CanonicalExpenseCategory(
                source_key=f"expense-category:{number}", name=name[:120], raw=record
            )

    def _expenses(self, transport, ctx):
        names = {}
        for row in transport.iter_records("msrftype"):
            record = _lower(row)
            number = _to_int(record.get("msrofno"))
            if number is not None:
                names[number] = _clean(record.get("msrofname"))
        for record in self._cash_rows(transport, ctx, CASH_EXPENSE):
            amount = _to_decimal(record.get("price"))
            if amount <= 0:
                continue
            category = _to_int(record.get("masrofno"))
            yield canonical.CanonicalExpense(
                source_key=f"expense:{_clean(record.get('srfethenno'))}",
                category_name=names.get(category, "مصروفات أخرى"),
                description=_clean(record.get("notes")),
                amount=amount,
                payment_method="cash",
                occurred_at=_parse_dt(record.get("date1")),
                reference=_clean(record.get("eysaldaftar"))[:128],
                raw=record,
            )

    def _money_accounts(self, transport, ctx):
        """The cash box, opened at the balance the source's own entry states."""
        opening = ZERO
        opening_at = None
        for record in self._cash_rows(transport, ctx, CASH_OPENING):
            opening += _to_decimal(record.get("price"))
            when = _parse_dt(record.get("date1"))
            if when is not None and (opening_at is None or when < opening_at):
                opening_at = when

        rows = list(transport.iter_records("bank"))
        if not rows and opening == ZERO:
            return
        if not rows:
            rows = [{"BankNo": 1, "BaankName": "الخزينة الرئيسية"}]
        for row in rows:
            record = _lower(row)
            number = _to_int(record.get("bankno"))
            name = _clean(record.get("baankname")) or "الخزينة الرئيسية"
            yield canonical.CanonicalMoneyAccount(
                source_key=f"money-account:{number}",
                name=name[:120],
                kind="cash",
                opening_balance=opening.quantize(_MONEY),
                opening_at=opening_at.date() if opening_at else None,
                is_default=True,
                is_active=True,
                notes="رُحّل الرصيد الافتتاحي من النظام السابق.",
                raw=record,
            )
            # One box. A second row would need its own opening figure, which
            # the source does not separate.
            break

    # --- people ----------------------------------------------------------
    def _employees(self, transport, ctx):
        for row in transport.iter_records("aamldata"):
            record = _lower(row)
            number = _to_int(record.get("aamlno"))
            name = _clean(record.get("aamlname"))
            if number is None or not name:
                continue
            salary = _to_decimal(record.get("mortb"))
            hours = _to_decimal(record.get("saaatalaml"))
            yield canonical.CanonicalEmployee(
                source_key=f"employee:{number}",
                full_name=name[:255],
                phone=_clean(record.get("mobile"))[:64],
                hire_date=_as_date(_parse_dt(record.get("startdate"))),
                notes=_clean(record.get("nation")),
                pay_amount=salary if salary > 0 else None,
                pay_type="monthly_salary",
                salary_type="monthly_fixed",
                standard_daily_hours=hours if ZERO < hours <= Decimal("24") else None,
                raw=record,
            )

    def _payroll_runs(self, transport, ctx):
        """Past salary months, one run per period.

        ``mortbat`` holds a row per employee per month. ``HrkaMonth``/
        ``HrkaYear`` is the period being paid for and is authoritative — the
        entry date routinely lags it by weeks — so the run is filed under the
        month it pays, which is where the profit report expects it.

        ``HrkaType`` separates the two kinds of row: ``1`` is the salary earned
        (in ``Mortab``/``Safii``), ``2`` is money handed over against it (in
        ``Kima``, with the salary columns left at zero). Only the first is a
        payroll line; the second would add a month of zero-value lines.

        An employee can appear twice in one month, and does: one shop accrued
        600 twice in June and paid 1,200 on the 16th. Pointy allows an employee
        one line per run, so the rows are summed — which is also what the shop
        was owed, rather than a choice between two halves of it.
        """
        runs: dict[tuple[int, int], dict] = {}
        for row in transport.iter_records("mortbat"):
            record = _lower(row)
            employee = _to_int(record.get("aamlno"))
            year = _to_int(record.get("hrkayear"))
            month = _to_int(record.get("hrkamonth"))
            if employee is None or not year or not month or not 1 <= month <= 12:
                continue
            gross = _to_decimal(record.get("mortab"))
            additions = _to_decimal(record.get("edafi")) + _to_decimal(record.get("other"))
            deductions = _to_decimal(record.get("kiab"))
            net = _to_decimal(record.get("safii"))
            if gross <= 0 and net <= 0:
                continue
            run = runs.setdefault((year, month), {"paid_at": None, "lines": {}})
            paid_at = _parse_dt(record.get("hrkadate"))
            if paid_at is not None and (
                run["paid_at"] is None or paid_at > run["paid_at"]
            ):
                run["paid_at"] = paid_at
            line = run["lines"].get(employee)
            if line is None:
                run["lines"][employee] = canonical.CanonicalPayrollLine(
                    employee_source_key=f"employee:{employee}",
                    gross_amount=gross,
                    additions=additions,
                    deductions=deductions,
                    net_amount=net,
                    description=_clean(record.get("notes")),
                )
                continue
            line.gross_amount += gross
            line.additions += additions
            line.deductions += deductions
            line.net_amount += net

        for (year, month), run in sorted(runs.items()):
            start = date(year, month, 1)
            end = _month_end(start)
            yield canonical.CanonicalPayrollRun(
                source_key=f"payroll:{year:04d}-{month:02d}",
                period_start=start,
                period_end=end,
                payment_date=_as_date(run["paid_at"]) or end,
                notes="رُحّل من النظام السابق",
                lines=[run["lines"][key] for key in sorted(run["lines"])],
            )


def _as_date(value) -> date | None:
    if value is None:
        return None
    return value.date() if isinstance(value, datetime) else value


def _month_end(start: date) -> date:
    if start.month == 12:
        return date(start.year, 12, 31)
    return date(start.year, start.month + 1, 1) - timedelta(days=1)
