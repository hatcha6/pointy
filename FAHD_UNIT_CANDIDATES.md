# منتجات تُباع بالجملة — Fahd unit candidates

Generated 2026-07-05 from the client's own sale history (fahd_migration.sqlite).

> **STATUS UPDATE (same day):** all candidates below were confirmed and their
> fixups are now **baked into `deploy/onprem/backfill-fahd-units.sh`** — one
> run applies the backfill *and* every per-product fix. Prices were re-derived
> from the shop's **2026 sales only** (several rose vs the all-time numbers
> below, e.g. مياه دجلة 5.50 not 4.00; ماجي prices its ×105 case at exactly
> 18.00). The soda sweep (العين، بيبسي، مشروب غازي…) showed packs already price
> correctly via piece×count **except بيبسي 1.75لتر** (pack ×6 pinned at 30.00).
>
> **Still open for the client:**
> 1. «صنف 1» (barcode `1`) — fixed as a fractional طبق ×30 @ 16.00, but it
>    needs a real product name.
> 2. كيكة اونو — sells in bulk but has no pack size in the data; ask the count.
> 3. سن توب ×21 — unusual pack count, worth double-checking.
> 4. بيبسي 1.75لتر — the *piece* price in the catalog says 5.50 but the shop
>    sells at 5.00; consider repricing the piece (the pack is already fixed).

**The pattern (same as the eggs):** the shop rings these through the *piece*
barcode at a discounted per-piece price whenever a whole pack (شد / علبة / طبق)
is sold. The pack units now exist in Pointy (from the old system's pack codes),
but their **sale price is derived** (piece × count) — i.e. the pack currently
charges full retail, while the shop's history shows it actually sells cheaper.

**What to confirm with the client, per product:** (1) what the pack is called and
how many pieces it holds (the detected factor below), (2) the pack's sale price
(suggested from their own modal bulk sales), (3) whether they sell half-packs
(then the unit should allow fractions, like the egg trays).

**How to apply once confirmed** (per product, on the server):

```bash
docker compose exec -T backend python manage.py set_product_unit \
  --product=<piece-barcode> --unit=<code> --unit-name=<الاسم> \
  --factor=<count> --price=<pack price> [--fractional] [--take-over=carton]
```

`--take-over=carton` moves the pack's barcode from the auto-created كرتون unit
onto the corrected unit — use it when the confirmed unit replaces that ×N pack.

## Already fixed (client confirmed)

| المنتج | الوحدة | العبوة | سعر البيع |
|---|---|---|---|
| بيض مائدة (6930358682129) | طبق، كسور مسموحة | ×30 | 15.00 |
| بيض مائدة (6930358682129) | كرتون = 12 طبق | ×360 | 180.00 (التكلفة 162) |
| بيض عربي (21) | طبق، كسور مسموحة | ×30 | 20.00 |
| بيض احمر (-1) | طبق، كسور مسموحة | ×30 | 17.50 |
| بيض صغير (01) | طبق، كسور مسموحة | ×30 | 7.00 |

## Candidates to confirm (strongest evidence first)

Suggested pack price = the shop's own most-frequent bulk per-piece price × the
pack count from the old system. `bulk sales` = number of receipt lines at that
bulk price.

| المنتج | الباركود | قطاعي | عبوة قديمة | سعر القطعة بالجملة | سعر العبوة المقترح | bulk sales |
|---|---|---|---|---|---|---|
| سن توب سعودي 125 مل | 6281012033178 | 0.75 | ×21 ⚠️ | 0.50 | 10.50 (لو ×21) | 5,186 |
| مياه شيماء 500مل | 6240000403041 | 0.50 | ×12 | 0.375 | **4.50** | 4,416 |
| «صنف 1» بدون اسم ⚠️ | 1 | 0.75 | ×30 | 0.533 | 16.00 (لو ×30) | 3,678 |
| مرقة دجاج ماجي | 97 | 0.25 | ×105 ⚠️ | 0.125 | يحتاج تأكيد | 2,910 |
| مياه اونو 0.330لتر | 6241478523606 | 0.50 | ×12 | 0.25 | **3.00** | 1,912 |
| مياه دجلة 0.5لتر | 6240000669027 | 0.50 | ×12 | 0.333 | **4.00** | 1,900 |
| مياه اونو 0.5لتر | 6241478523613 | 0.50 | ×12 | 0.375 | **4.50** | 1,709 |
| مياه النبع 500مل | 6240000017026 | 0.75 | ×12 | 0.50 | **6.00** | 1,217 |
| مياه شيماء 330مل | 6240000403034 | 0.50 | ×12 | 0.333 | **4.00** | 1,094 |
| شكلاطة كريس كروس | 8691707091853 | 0.75 | ×24 | 0.50 | 12.00 | 1,039 |
| مياه اكوافينا 0.5لتر | 6241000051690 | 0.50 | ×12 | 0.375 | **4.50** | 900 |
| شكلاطة غوفرش | 8691707095127 | 0.75 | ×24 | 0.50 | 12.00 | 782 |
| مياه الضيافة قنينة 200 | 6240000319069 | 0.50 | ×12 | 0.25 | **3.00** | 720 |
| شكلاطة غولد | 8691707095707 | 0.75 | ×24 | 0.50 | 12.00 | 581 |
| حليب الريحان 125مل | 6241000011915 | 1.25 | ×18 | 1.00 | 18.00 | 367 |
| مشروب سفن/ببسي/مريندا 185مل | 6212552012286 | 2.50 | ×30 | 1.50 | 45.00 | 316 |
| عصير نضال صغير 250مل | 6224003287020 | 2.75 | ×12 | 2.50 | 30.00 | 289 |
| كيكة اونو | 6194021101984 | 1.25 | لا يوجد كود عبوة | 1.00 | يحتاج عدد العبوة | 284 |
| مياه الضيافة 0.5لتر | 6240000319021 | 0.50 | ×12 | 0.292 | **3.50** | 265 |
| بسكويت واحات اونو | 6285602008263 | 1.00 | ×16 | 0.50 | 8.00 | 240 |
| شيماء 0.22لتر | 6240000403133 | 0.50 | ×12 | 0.3125 | **3.75** | 215 |
| مشروب غازي علبة صغيرة | 012000801655 | 2.50 | ×30 | 2.00 | 60.00 | 145 |
| مياه مرمرة 0.5 | 6241002380026 | 0.50 | ×12 | 0.375 | **4.50** | 114 |
| كيك ايطالي | 80633044 | 1.00 | ×10 | 0.90 | 9.00 | 95 |

### Notes / anomalies worth raising with the client

- **«صنف 1» (barcode `1`)**: a *placeholder-named* product with 28,758 sale
  lines, sold mostly in ~30-piece bulks at 0.533 — the profile screams "another
  egg product" (tray of 30 ≈ 16.00). Ask the client what item this actually is
  and name it properly.
- **مرقة ماجي (97)**: pack code says ×105 (likely the master case); bulk sales
  happen at ~6–12 pieces at *half* retail — the real selling unit is probably a
  strip/علبة of 12 or 24. Confirm the size and price; the ×105 case can stay as
  a second unit.
- **سن توب ×21**: 21 per pack is unusual (real cartons are 18/24); confirm.
- **Water bottles (all brands)**: the ×12 شد at the bold suggested prices is the
  clearest, highest-volume win after eggs — worth confirming as a batch.
- Products sold in half-packs need `--fractional` (like egg trays) — ask while
  confirming prices.
