# Weighing Scales — Barcode Nomenclature + PLU Push

**Date:** 2026-09-11
**Status:** Built. Phases 1–4 shipped; the CAS wire format's numeric
layout is the one thing still unverified against real hardware (see §6).
**Trigger:** Sufian (reference grocery) is moving into produce and buying a label
printing scale. Today Pointy reads exactly one scale label layout, hard-coded,
and reads every other layout **wrong without saying so**.
**Mirrors inspected:** Odoo 18 `barcodes/models/barcode_nomenclature.py` (rule
model, `sanitize_ean`, base-code masking), ERPGulf `scale` app for ERPNext
(per-shop prefix/position settings), Erply's embedded weight/price article,
CAS CL5000 Network Manual rev. 2006-08-31 (TCP 20304, `W02A` PLU download),
Aclas LS2X manuals (FTP + TCP PLU upload).

Two constraints govern every decision below.

> **A wrong quantity must never be silent.** A scale label that this shop's
> rules do not describe rings as a plain barcode or does not ring at all. It
> never rings as "1.25 kg" because 1250 happened to sit where grams were
> expected.

> **The scale is a satellite, not a second catalog.** Prices live in Pointy and
> are pushed out. A scale whose price disagrees with the till is the exact
> "numbers you cannot trust" failure we sell against, so the push has to be
> boring, repeatable, and verifiable — including for shops whose scale we
> cannot reach over the wire.

---

## 1. What is broken today

`frontend/lib/src/shared/barcode/scale_barcode.dart` assumes one layout:

```
2 P IIIII WWWWW C      prefix 2x · 5-digit item code · 5 digits of GRAMS · check
```

Three defects follow, in descending severity.

**1.1 A price-embedded label books a wrong quantity, silently.** Most Chinese
scales (and every scale configured for pre-packed goods) print the *price* in
those five digits. A 12.50 LYD sticker becomes `01250`, which the current parser
reads as 1.250 kg. The line then prices at 1.25 × the kilo price. Nothing warns.
For a 40 LYD/kg cheese the till charges 50.00 for a 12.50 sticker.

**1.2 The catalog's own base code does not resolve.** Shops that print shelf
labels store the full 13-digit EAN with zeros in the value field
(`2112345000008`). Scanning that hits no rule (value is 0) and then fails the
exact-barcode match only because the stored code is the *masked* one with its own
check digit. Odoo solves this with `base_code`: zero the value digits, recompute
the check digit, match on that. We never compute it.

**1.3 The weight is applied on a string comparison.** `variant.unit != 'piece'`
decides whether the embedded value becomes the quantity. Any product whose base
unit is `box` — a counted thing — passes that test and will happily take 0.750
from a label. The real question is `allows_fractional`, which the backend already
resolves per unit (`apps/catalog/units.py`).

And the write half does not exist at all: prices are retyped into the scale by
hand, so scale price and till price drift apart the first time anything is
repriced.

---

## 2. Research: what the mirrors do

**Odoo — barcode nomenclature.** An ordered list of rules; each is
`(sequence, type, encoding, pattern)`. The pattern uses `.` for any digit and
`{NNDDD}` for the embedded value, `N` = integer digits, `D` = decimal digits.
Types include *weighted product*, *priced product*, *discounted product*.
On match it produces a **base code**: the value digits replaced with zeros and,
for EAN-13/UPC-A, the check digit recomputed (`sanitize_ean`). Product lookup
then happens on the base code. This is the right shape and we take it.

What we change: Odoo's dots leave the item-code positions implicit. We name every
digit's job explicitly, which makes a rule self-describing in the UI and lets us
validate a rule at save time instead of at the till.

**ERPGulf `scale` (ERPNext).** Confirms the practical configuration surface a
shop actually needs — prefix, item-code positions, weight *and* price settings —
and that "supporting any brand" in practice means *configurable positions*, not a
driver per brand. There is no PLU push; ERPNext shops retype prices too.

**Erply.** Confirms the 12/13-digit family, the 5–6 character product code, and —
usefully — that price and weight labels are structurally identical, so the
meaning **must** come from configuration, not from sniffing the digits. This is
the strongest argument for refusing to guess.

**CAS CL5000 Network Manual.** A real, implementable protocol:
TCP **20304**; commands prefixed `R` (read) `W` (write) `C` (command) `I` (info);
PLU download is

```
W02A<pluno>,<deptno>L<size>:<data blocks><bcc>
<data block> := "F="<ptype>"."<stype>","<size>":"<data>
bcc := XOR over the data blocks
```

with a typed field table (Name = ptype 10, `S`, 40 bytes; Price = 6, `L`, 4 bytes
big-endian; Item Code = 11, `L`, 4; Unit Weight = 5, `B`, 1; Tare = 13, `L`, 4;
Department = 1, `W`, 2; PLU No = 2, `L`, 4 — the manual's worked example encodes
PLU 1000 as `03 E8 00 00`, i.e. a big-endian value in a 4-byte field).

**Aclas LS2/LS2X.** Ethernet + RS232, FTP and TCP/IP PLU upload via their Link32
handshake. The handshake spec is not public; the FTP path is.

**Rongta / Digi / the long tail of Chinese scales.** PLU loading is done by the
vendor's Windows tool importing a CSV/XLS, or from a USB stick. There is no
protocol to speak. This is the majority of the Libyan market and it decides the
architecture: **the universal driver is a file, not a socket.**

---

## 3. Design — Part 1: barcode nomenclature (the read half)

### 3.1 The rule

New model `catalog.ScaleBarcodeRule`. A shop has an ordered list; first match
wins. Parsing itself is a pure function over a frozen rule set
(`apps/catalog/scale_barcodes.py`) so the identical logic can be mirrored in Dart
and tested with one shared vector table.

| Field | Meaning |
|---|---|
| `name` | "Produce scale — weight" |
| `sequence` | Match order; first match wins |
| `pattern` | Per-digit map, below |
| `value_kind` | `weight` · `price` · `count` |
| `value_decimals` | How many of the value digits are decimal (grams in 5 digits → 3) |
| `value_unit` | UoM code the value is in once scaled (`kg` default; only for `weight`) |
| `require_check_digit` | Off for cheap scales that print a wrong one |
| `is_active` | |

**Pattern language** — one character per digit position, total length = the code
length the rule matches:

```
0-9   literal digit (the prefix)        I  item-code digit
V     embedded value digit              C  check digit
X     ignored digit (some scales print a department or an internal check here)
```

So the two formats the field will hit are:

```
21IIIIIVVVVVC     weight, value_decimals 3   → 21 12345 01500 2  = 1.500 kg
23IIIIIVVVVVC     price,  value_decimals 2   → 23 12345 01250 7  = 12.50 LYD
```

Seeded defaults follow the GS1 in-store convention (`20`–`29` reserved for
in-store use): `21…` weight, `23…` price — matching Odoo's defaults, so a shop
whose scale ships with factory settings works untouched.

### 3.2 Matching

1. Exact barcode match first, always. A genuine supplier EAN that happens to
   start with `2` keeps winning over any rule. (Already true; keep it.)
2. First active rule whose length and literal digits match, and whose check digit
   verifies (unless the rule says not to).
3. Build candidates, most specific first:
   - **base code** — value digits zeroed, check digit recomputed (Odoo's rule),
   - prefix + item code as printed,
   - item code alone, and without leading zeros.
4. First candidate that resolves is the product.

### 3.3 Value → quantity

- `weight` — value is in `value_unit`; convert to the product's sale unit through
  `UnitOfMeasure.reference_factor` (a product stocked in `g` takes 1500, one in
  `kg` takes 1.5). Never cross dimensions.
- `count` — value is the quantity.
- `price` — the label carries money, so quantity must be derived:
  `quantity = value / effective_unit_price`, quantized to the 3 decimals
  `OrderLine.quantity` stores. The server prices the line (client prices are
  never trusted — `apps/sales/serializers.py`), so the ringing total is
  `unit_price × quantity` and can differ from the sticker by a rounding step.
  The cashier is told when it does, rather than the drift being hidden.

### 3.4 Edge cases — each one gets a test on both sides

| Case | Behaviour |
|---|---|
| No rule matches | Plain barcode. No quantity inference. |
| Wrong check digit, rule requires it | No match → plain barcode |
| Value digits are all zero | The shop's own shelf label: resolve product, quantity 1 |
| Price rule, `unit_price` = 0 | Resolve product, quantity 1, warn — never divide |
| Price rule, quantity rounds to 0 | Quantity 1, warn |
| Product's unit forbids fractions | Do not apply an embedded weight; quantity 1, warn |
| Rounding drift > 1 money step | Ring it, and say so on the line |
| Two rules could match | Lower `sequence` wins; save-time validation refuses two active rules with the same length + literals |
| Item code resolves to nothing | Not found — same as any unknown barcode |
| Non-digits, wrong length, whitespace, scanner prefix | Normalized then rejected cleanly |
| Unit (carton) barcode that also matches a rule | Unit barcode wins; a carton is never a weight |

---

## 4. Design — Part 2: PLU push (the write half)

New app `apps.scales` (depends on catalog; nothing depends on it).

- **`Scale`** — name, driver key, connection (host/port, or none for file), scale
  and department id, the `ScaleBarcodeRule` its labels use, `is_active`,
  `last_push_at`.
- **`ScaleItem`** — the products that live on scales: `variant`, a **stable**
  `plu_number` (unique, allocated once and never reused), tare, label id,
  shelf-life days. Stability is the whole point: a PLU that moves turns every
  sticker already on a shelf into a label for the wrong product.
- **`ScalePushJob`** — one push, its driver, its outcome per item, so "did the
  new price reach the scale?" has an answer that is not "probably".

**Drivers** (`apps/scales/drivers/`, mirroring `surveillance/drivers/`):

| Driver | Transport | Notes |
|---|---|---|
| `cas_cl5000` | TCP 20304 | Real protocol from the manual; CL5000/5200/5500/7200 |
| `aclas_ftp` | FTP | LS2/LS2X family; writes the PLU file the scale reads |
| `file_export` | File | **The universal one.** CSV/TXT in the column order the shop's vendor tool expects, for Rongta/Digi/no-name Chinese scales. Downloaded, or dropped on a USB stick. |

`file_export` is not a fallback we are embarrassed about — for most of this
market it is the only thing that works, and it works for every scale ever sold.
It ships first.

---

## 5. Phases — all shipped

1. **Nomenclature, backend** — `catalog.ScaleBarcodeRule`, the pure parser in
   `catalog/scale_barcodes.py`, the seeded compatibility rule, resolution wired
   into the price checker, `/api/scale-barcode-rules/`, permissions, 34 tests.
2. **Nomenclature, frontend** — the Dart mirror in
   `shared/barcode/scale_barcode.dart` fed by the rules endpoint and cached on a
   TTL, the POS quantity + warning line, the settings screen with its
   "try a label" field, 29 tests sharing the backend's vectors.
3. **PLU push, backend** — `apps.scales` with `file_export`, `cas_cl5000` and
   `aclas_ftp`, `catalog.ScalePlu` for stable numbers, the push job and its
   history, 44 tests.
4. **PLU push, frontend** — the scales screen: add/edit, reachability check,
   push with an honest status, PLU file download, PLU assignment.

## 6. What is not proven

- **The CAS numeric field layout.** Built from the manual's one worked example
  (`03 E8 00 00` for 1000). `byte_order` switches it to plain big- or
  little-endian without a code change; the first real CL5000 settles it.
- **The Aclas FTP file shape.** The transport is right; the columns its
  importer expects are a per-model setting and default to the common order.
- **Nothing has been pushed to a physical scale.** Every driver is tested
  against its own wire output, not against hardware.
