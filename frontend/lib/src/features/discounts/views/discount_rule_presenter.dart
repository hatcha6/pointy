import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/discount_rule.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';

String discountChannelLabel(AppLocalizations l10n, DiscountChannel channel) {
  return switch (channel) {
    DiscountChannel.sales => l10n.discountChannelSales,
    DiscountChannel.purchasing => l10n.discountChannelPurchasing,
    DiscountChannel.both => l10n.discountChannelBoth,
  };
}

String discountApplicationLabel(
  AppLocalizations l10n,
  DiscountApplicationType type,
) {
  return switch (type) {
    DiscountApplicationType.automatic => l10n.discountApplicationAutomatic,
    DiscountApplicationType.couponCode => l10n.discountApplicationCoupon,
  };
}

String discountScopeLabel(AppLocalizations l10n, DiscountScope scope) {
  return switch (scope) {
    DiscountScope.document => l10n.discountScopeDocument,
    DiscountScope.line => l10n.discountScopeLine,
  };
}

String discountValueTypeLabel(AppLocalizations l10n, DiscountValueType type) {
  return switch (type) {
    DiscountValueType.percentage => l10n.discountValueTypePercentage,
    DiscountValueType.fixedAmount => l10n.discountValueTypeFixedAmount,
    DiscountValueType.fixedUnitAmount => l10n.discountValueTypeFixedUnitAmount,
    DiscountValueType.fixedPrice => l10n.discountValueTypeFixedPrice,
  };
}

String discountRoundingModeLabel(
  AppLocalizations l10n,
  DiscountRoundingMode mode,
) {
  return switch (mode) {
    DiscountRoundingMode.none => l10n.discountRoundingModeNone,
    DiscountRoundingMode.down => l10n.discountRoundingModeDown,
    DiscountRoundingMode.nearest => l10n.discountRoundingModeNearest,
    DiscountRoundingMode.up => l10n.discountRoundingModeUp,
  };
}

String discountValueText(AppLocalizations l10n, DiscountRule rule) {
  return switch (rule.valueType) {
    DiscountValueType.percentage => l10n.discountPercentageValue(
      rule.value.toStringAsFixed(2),
    ),
    DiscountValueType.fixedAmount ||
    DiscountValueType.fixedUnitAmount ||
    DiscountValueType.fixedPrice => formatMoney(rule.value),
  };
}

List<String> discountRuleFacts(AppLocalizations l10n, DiscountRule rule) {
  return [
    l10n.discountValueSummary(
      discountValueTypeLabel(l10n, rule.valueType),
      discountValueText(l10n, rule),
    ),
    l10n.discountPrioritySummary(rule.priority),
    if (rule.couponCode.isNotEmpty) l10n.discountCouponSummary(rule.couponCode),
    if (rule.minOrderSubtotal > 0)
      l10n.discountMinSubtotalSummary(formatMoney(rule.minOrderSubtotal)),
    if (rule.minLineQuantity != null)
      l10n.discountMinLineQuantitySummary(rule.minLineQuantity!),
    if (rule.maxDiscountAmount != null)
      l10n.discountMaxAmountSummary(formatMoney(rule.maxDiscountAmount!)),
    if (rule.roundingMode != DiscountRoundingMode.none &&
        rule.roundingIncrement != null)
      l10n.discountRoundingSummary(
        discountRoundingModeLabel(l10n, rule.roundingMode),
        formatMoney(rule.roundingIncrement!),
      ),
    if (rule.usageLimit != null)
      l10n.discountUsageSummary(rule.redemptionCount, rule.usageLimit!),
    if (rule.usageLimit == null)
      l10n.discountUsageCountSummary(rule.redemptionCount),
    l10n.discountAppliedCountSummary(rule.appliedCount),
    if (rule.startsAt != null)
      l10n.discountStartsAtSummary(formatDateTime(rule.startsAt!)),
    if (rule.endsAt != null)
      l10n.discountEndsAtSummary(formatDateTime(rule.endsAt!)),
    if (rule.products.isNotEmpty)
      l10n.discountProductConstraintSummary(rule.products.length),
    if (rule.variants.isNotEmpty)
      l10n.discountVariantConstraintSummary(rule.variants.length),
    if (rule.productCategories.isNotEmpty)
      l10n.discountProductCategoryConstraintSummary(
        rule.productCategories.length,
      ),
    if (rule.customers.isNotEmpty)
      l10n.discountCustomerConstraintSummary(rule.customers.length),
    if (rule.suppliers.isNotEmpty)
      l10n.discountSupplierConstraintSummary(rule.suppliers.length),
  ];
}
