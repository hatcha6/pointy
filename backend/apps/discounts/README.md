# Discounts

Pointy discounts are calculated by the backend and persisted as immutable audit
snapshots. The frontend can preview or submit coupon codes, but sales and
purchasing totals are always recalculated on the server.

## Model

- `DiscountRule` is the mutable configuration record. A rule can target sales,
  purchasing, or both; automatic application or coupon codes; document or line
  scope; percentage, fixed document/line amount, fixed unit amount, or fixed
  price values, plus the quantity promotions below.
- `DiscountTier` rows belong to a `tiered` rule (one per quantity break).

## Quantity Promotions

Three line-scoped value types price a **pool of whole units** gathered across
every line the rule matches (mix-and-match), instead of the flat per-line
`value` math. Only whole units take part — a fractional remainder on a weighed
line (e.g. 1.5 kg) never joins a group and keeps its full price. They reuse the
per-line allocation/cap/rounding/snapshot machinery, so receipts, returns, and
the price checker need no special handling.

- `multi_buy` — N units for a fixed group price. `group_size` = N, `value` = the
  group price. The **most-expensive** units form the priced groups; the cheaper
  remainder stays full price. Self-stacks (2×N units → two priced groups). E.g.
  "3 for 1.00 instead of 1.50".
- `tiered` — wholesale-style price breaks via `DiscountTier(min_quantity,
  unit_price)` rows. Once the pooled count of whole units reaches a tier, **every**
  whole unit reprices to that tier's `unit_price`; the highest satisfied tier
  wins; units already cheaper than the tier price are untouched. `value` is set by
  the serializer to the cheapest tier price (the headline "from" price).
- `buy_x_get_y` — buy `buy_quantity` to reward `get_quantity` units per block. The
  **cheapest** units in the pool are the rewarded ones (standard BOGO).
  `reward_type` is `free` (100% off), `percentage` (`value`% off), or
  `fixed_price` (rewarded units down to `value`).

All three are enforced line-scoped, reject `min_line_quantity` (they set their
own threshold), and are `exclusive` by default. The pooled algorithms live in
`DiscountEngine._pooled_allocations` and friends.
- `AppliedDiscount` is the immutable document snapshot. It records the rule
  name, coupon code, source, value, priority, exclusivity, source subtotal,
  total discount, and line allocations as they were at calculation time.
- `DiscountRedemption` records usage for global, customer, and supplier usage
  limits. Redemptions are linked to snapshots when a document is persisted.

Rules are ordered by `priority` then `id`. Rules are exclusive by default; set
`exclusive=False` only when a discount may stack with later rules. An exclusive
rule that applies stops later rules, and an exclusive rule after an applied
discount is skipped.

## Calculation Flow

1. The integration builds a `DiscountContext` with channel, customer or
   supplier, optional coupon codes, and `DiscountLineInput` rows.
2. `DiscountEngine.calculate()` filters active, in-window rules by channel,
   coupon, minimum subtotal, product/customer/supplier constraints, and usage
   limits.
3. Each applied rule allocates cents across eligible lines with `Decimal`
   arithmetic and deterministic `0.01` rounding. Later stackable rules discount
   only the remaining line balance.
4. Sales persist `Order.discount_total` and `OrderLine.discount_total`.
   Payments are validated against the discounted order total.
5. Purchases persist `PurchaseOrder.discount_total`,
   `PurchaseLine.discount_amount`, `net_line_total`, and `net_unit_cost`.
   Landed costs are allocated after discounts, using discounted line value for
   value-based allocation.
6. `persist_applied_discounts()` stores the immutable snapshots and redemptions
   after document lines exist, including persisted line ids and product ids in
   allocation metadata.

Returns, voids, purchase returns, purchase refunds, and purchase exchanges use
the stored discounted line economics. They do not re-read mutable discount rules.

## Adding A Discount Type

1. Add a `DiscountRule.ValueType` value and migration.
2. Extend `DiscountRule.clean()` and `DiscountRuleSerializer.validate()` if the
   type has scope or value constraints.
3. Add the calculation branch in `DiscountEngine._rule_allocations()`.
4. Add engine tests for rounding, caps, stacking, restrictions, and zero/limit
   behavior.
5. Add sales and purchasing integration tests if the new type affects persisted
   line totals or landed-cost weights.
6. Keep snapshots backward compatible by preserving existing
   `AppliedDiscount` fields and adding optional metadata when possible.

## Tax

There is no active tax calculation or tax UI surface in Pointy. Discount tests
and serializers should not add tax fields or tax totals unless tax support is
explicitly requested as a separate feature.
