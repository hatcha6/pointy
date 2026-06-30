import 'contact.dart';
import 'query.dart';

enum DiscountChannel {
  sales('sales'),
  purchasing('purchasing'),
  both('both');

  const DiscountChannel(this.apiValue);

  final String apiValue;

  static DiscountChannel fromApi(String value) {
    return DiscountChannel.values.firstWhere(
      (channel) => channel.apiValue == value,
      orElse: () => DiscountChannel.sales,
    );
  }
}

enum DiscountApplicationType {
  automatic('automatic'),
  couponCode('coupon_code');

  const DiscountApplicationType(this.apiValue);

  final String apiValue;

  static DiscountApplicationType fromApi(String value) {
    return DiscountApplicationType.values.firstWhere(
      (type) => type.apiValue == value,
      orElse: () => DiscountApplicationType.automatic,
    );
  }
}

enum DiscountScope {
  document('document'),
  line('line');

  const DiscountScope(this.apiValue);

  final String apiValue;

  static DiscountScope fromApi(String value) {
    return DiscountScope.values.firstWhere(
      (scope) => scope.apiValue == value,
      orElse: () => DiscountScope.document,
    );
  }
}

enum DiscountValueType {
  percentage('percentage'),
  fixedAmount('fixed_amount'),
  fixedUnitAmount('fixed_unit_amount'),
  fixedPrice('fixed_price'),
  multiBuy('multi_buy'),
  tiered('tiered'),
  buyXGetY('buy_x_get_y');

  const DiscountValueType(this.apiValue);

  final String apiValue;

  /// The quantity promotions priced over a pool of whole units. They are always
  /// line-scoped and configured with their own parameters instead of [value]
  /// alone.
  bool get isQuantityPromotion =>
      this == multiBuy || this == tiered || this == buyXGetY;

  static DiscountValueType fromApi(String value) {
    return DiscountValueType.values.firstWhere(
      (type) => type.apiValue == value,
      orElse: () => DiscountValueType.percentage,
    );
  }
}

enum DiscountBuyGetReward {
  free('free'),
  percentage('percentage'),
  fixedPrice('fixed_price');

  const DiscountBuyGetReward(this.apiValue);

  final String apiValue;

  static DiscountBuyGetReward fromApi(String value) {
    return DiscountBuyGetReward.values.firstWhere(
      (reward) => reward.apiValue == value,
      orElse: () => DiscountBuyGetReward.free,
    );
  }
}

/// A single wholesale price break for a [DiscountValueType.tiered] rule: once a
/// customer reaches [minQuantity] units, each unit reprices to [unitPrice].
class DiscountTier {
  const DiscountTier({required this.minQuantity, required this.unitPrice});

  final int minQuantity;
  final double unitPrice;

  factory DiscountTier.fromJson(Map<String, Object?> json) {
    return DiscountTier(
      minQuantity: _intFromJson(json['min_quantity']),
      unitPrice: _doubleFromJson(json['unit_price']),
    );
  }
}

enum DiscountRoundingMode {
  none('none'),
  down('down'),
  nearest('nearest'),
  up('up');

  const DiscountRoundingMode(this.apiValue);

  final String apiValue;

  static DiscountRoundingMode fromApi(String value) {
    return DiscountRoundingMode.values.firstWhere(
      (mode) => mode.apiValue == value,
      orElse: () => DiscountRoundingMode.none,
    );
  }
}

enum DiscountRuleStatusFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false'));

  const DiscountRuleStatusFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum DiscountRuleChannelFilter implements QueryFilterSet {
  all(null),
  sales(QueryFilter(parameter: 'channel', value: 'sales')),
  purchasing(QueryFilter(parameter: 'channel', value: 'purchasing')),
  both(QueryFilter(parameter: 'channel', value: 'both'));

  const DiscountRuleChannelFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum DiscountRuleApplicationFilter implements QueryFilterSet {
  all(null),
  automatic(QueryFilter(parameter: 'application_type', value: 'automatic')),
  couponCode(QueryFilter(parameter: 'application_type', value: 'coupon_code'));

  const DiscountRuleApplicationFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum DiscountRuleOrdering implements QueryOrdering {
  priority('priority'),
  name('name'),
  newest('-created_at'),
  updated('-updated_at');

  const DiscountRuleOrdering(this.apiValue);

  @override
  final String apiValue;
}

class DiscountRuleQuery extends ModelQuery {
  const DiscountRuleQuery({
    this.search = '',
    this.status = DiscountRuleStatusFilter.all,
    this.channel = DiscountRuleChannelFilter.all,
    this.application = DiscountRuleApplicationFilter.all,
    this.ordering = DiscountRuleOrdering.priority,
  });

  @override
  final String search;
  final DiscountRuleStatusFilter status;
  final DiscountRuleChannelFilter channel;
  final DiscountRuleApplicationFilter application;
  @override
  final DiscountRuleOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [
    ...status.filters,
    ...channel.filters,
    ...application.filters,
  ];

  int get activeFilterCount {
    return [
      status != DiscountRuleStatusFilter.all,
      channel != DiscountRuleChannelFilter.all,
      application != DiscountRuleApplicationFilter.all,
    ].where((isActive) => isActive).length;
  }

  DiscountRuleQuery copyWith({
    String? search,
    DiscountRuleStatusFilter? status,
    DiscountRuleChannelFilter? channel,
    DiscountRuleApplicationFilter? application,
    DiscountRuleOrdering? ordering,
  }) {
    return DiscountRuleQuery(
      search: search ?? this.search,
      status: status ?? this.status,
      channel: channel ?? this.channel,
      application: application ?? this.application,
      ordering: ordering ?? this.ordering,
    );
  }
}

class DiscountRulePage {
  const DiscountRulePage({required this.rules, required this.hasMore});

  final List<DiscountRule> rules;
  final bool hasMore;

  factory DiscountRulePage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(DiscountRule.fromJson)
        .toList(growable: false);
    return DiscountRulePage(rules: results, hasMore: json['next'] != null);
  }
}

class DiscountRulePerformance {
  const DiscountRulePerformance({
    required this.summary,
    required this.incrementality,
    required this.channelBreakdown,
    required this.monthlyTrend,
  });

  final DiscountPerformanceSummary summary;
  final DiscountIncrementality incrementality;
  final List<DiscountChannelPerformance> channelBreakdown;
  final List<DiscountTrendPoint> monthlyTrend;

  factory DiscountRulePerformance.fromJson(Map<String, Object?> json) {
    return DiscountRulePerformance(
      summary: DiscountPerformanceSummary.fromJson(
        _mapFromJson(json['summary']),
      ),
      incrementality: DiscountIncrementality.fromJson(
        _mapFromJson(json['incrementality']),
      ),
      channelBreakdown:
          (json['channel_breakdown'] as List<Object?>? ?? const [])
              .whereType<Map<String, Object?>>()
              .map(DiscountChannelPerformance.fromJson)
              .toList(growable: false),
      monthlyTrend: (json['monthly_trend'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(DiscountTrendPoint.fromJson)
          .toList(growable: false),
    );
  }
}

class DiscountPerformanceSummary {
  const DiscountPerformanceSummary({
    required this.redemptionCount,
    required this.applicationCount,
    required this.documentCount,
    required this.salesDocumentCount,
    required this.purchaseDocumentCount,
    required this.uniqueCustomerCount,
    required this.uniqueSupplierCount,
    required this.anonymousBeneficiaryCount,
    required this.beneficiaryCount,
    required this.influencedGross,
    required this.discountAmount,
    required this.influencedNet,
    required this.averageDiscountAmount,
    required this.averageDocumentValue,
    required this.discountRatePercent,
    required this.usageLimit,
    required this.remainingUsage,
    required this.usagePercent,
  });

  final int redemptionCount;
  final int applicationCount;
  final int documentCount;
  final int salesDocumentCount;
  final int purchaseDocumentCount;
  final int uniqueCustomerCount;
  final int uniqueSupplierCount;
  final int anonymousBeneficiaryCount;
  final int beneficiaryCount;
  final double influencedGross;
  final double discountAmount;
  final double influencedNet;
  final double averageDiscountAmount;
  final double averageDocumentValue;
  final double discountRatePercent;
  final int? usageLimit;
  final int? remainingUsage;
  final double? usagePercent;

  factory DiscountPerformanceSummary.fromJson(Map<String, Object?> json) {
    return DiscountPerformanceSummary(
      redemptionCount: _intFromJson(json['redemption_count']),
      applicationCount: _intFromJson(json['application_count']),
      documentCount: _intFromJson(json['document_count']),
      salesDocumentCount: _intFromJson(json['sales_document_count']),
      purchaseDocumentCount: _intFromJson(json['purchase_document_count']),
      uniqueCustomerCount: _intFromJson(json['unique_customer_count']),
      uniqueSupplierCount: _intFromJson(json['unique_supplier_count']),
      anonymousBeneficiaryCount: _intFromJson(
        json['anonymous_beneficiary_count'],
      ),
      beneficiaryCount: _intFromJson(json['beneficiary_count']),
      influencedGross: _doubleFromJson(json['influenced_gross']),
      discountAmount: _doubleFromJson(json['discount_amount']),
      influencedNet: _doubleFromJson(json['influenced_net']),
      averageDiscountAmount: _doubleFromJson(json['average_discount_amount']),
      averageDocumentValue: _doubleFromJson(json['average_document_value']),
      discountRatePercent: _doubleFromJson(json['discount_rate_percent']),
      usageLimit: _nullableIntFromJson(json['usage_limit']),
      remainingUsage: _nullableIntFromJson(json['remaining_usage']),
      usagePercent: _nullableDoubleFromJson(json['usage_percent']),
    );
  }
}

class DiscountIncrementality {
  const DiscountIncrementality({
    required this.method,
    required this.confidence,
    required this.baselinePeriodStart,
    required this.baselinePeriodEnd,
    required this.campaignPeriodStart,
    required this.campaignPeriodEnd,
    required this.baselineDays,
    required this.activeDays,
    required this.baselineDocumentCount,
    required this.baselineGross,
    required this.baselineAverageDocumentValue,
    required this.expectedDocumentsWithoutDiscount,
    required this.expectedGrossWithoutDiscount,
    required this.incrementalDocuments,
    required this.incrementalGross,
    required this.estimatedIncrementalNetValue,
    required this.liftPercent,
  });

  final String method;
  final String confidence;
  final DateTime? baselinePeriodStart;
  final DateTime? baselinePeriodEnd;
  final DateTime? campaignPeriodStart;
  final DateTime? campaignPeriodEnd;
  final int baselineDays;
  final int activeDays;
  final int baselineDocumentCount;
  final double baselineGross;
  final double baselineAverageDocumentValue;
  final double expectedDocumentsWithoutDiscount;
  final double expectedGrossWithoutDiscount;
  final double incrementalDocuments;
  final double incrementalGross;
  final double estimatedIncrementalNetValue;
  final double? liftPercent;

  factory DiscountIncrementality.fromJson(Map<String, Object?> json) {
    return DiscountIncrementality(
      method: json['method']?.toString() ?? '',
      confidence: json['confidence']?.toString() ?? '',
      baselinePeriodStart: _dateTimeFromJson(json['baseline_period_start']),
      baselinePeriodEnd: _dateTimeFromJson(json['baseline_period_end']),
      campaignPeriodStart: _dateTimeFromJson(json['campaign_period_start']),
      campaignPeriodEnd: _dateTimeFromJson(json['campaign_period_end']),
      baselineDays: _intFromJson(json['baseline_days']),
      activeDays: _intFromJson(json['active_days']),
      baselineDocumentCount: _intFromJson(json['baseline_document_count']),
      baselineGross: _doubleFromJson(json['baseline_gross']),
      baselineAverageDocumentValue: _doubleFromJson(
        json['baseline_average_document_value'],
      ),
      expectedDocumentsWithoutDiscount: _doubleFromJson(
        json['expected_documents_without_discount'],
      ),
      expectedGrossWithoutDiscount: _doubleFromJson(
        json['expected_gross_without_discount'],
      ),
      incrementalDocuments: _doubleFromJson(json['incremental_documents']),
      incrementalGross: _doubleFromJson(json['incremental_gross']),
      estimatedIncrementalNetValue: _doubleFromJson(
        json['estimated_incremental_net_value'],
      ),
      liftPercent: _nullableDoubleFromJson(json['lift_percent']),
    );
  }
}

class DiscountChannelPerformance {
  const DiscountChannelPerformance({
    required this.channel,
    required this.redemptionCount,
    required this.documentCount,
    required this.discountAmount,
    required this.influencedGross,
    required this.influencedNet,
  });

  final DiscountChannel channel;
  final int redemptionCount;
  final int documentCount;
  final double discountAmount;
  final double influencedGross;
  final double influencedNet;

  factory DiscountChannelPerformance.fromJson(Map<String, Object?> json) {
    return DiscountChannelPerformance(
      channel: DiscountChannel.fromApi(json['channel']?.toString() ?? ''),
      redemptionCount: _intFromJson(json['redemption_count']),
      documentCount: _intFromJson(json['document_count']),
      discountAmount: _doubleFromJson(json['discount_amount']),
      influencedGross: _doubleFromJson(json['influenced_gross']),
      influencedNet: _doubleFromJson(json['influenced_net']),
    );
  }
}

class DiscountTrendPoint {
  const DiscountTrendPoint({
    required this.period,
    required this.redemptionCount,
    required this.documentCount,
    required this.discountAmount,
    required this.influencedGross,
    required this.influencedNet,
  });

  final String period;
  final int redemptionCount;
  final int documentCount;
  final double discountAmount;
  final double influencedGross;
  final double influencedNet;

  factory DiscountTrendPoint.fromJson(Map<String, Object?> json) {
    return DiscountTrendPoint(
      period: json['period']?.toString() ?? '',
      redemptionCount: _intFromJson(json['redemption_count']),
      documentCount: _intFromJson(json['document_count']),
      discountAmount: _doubleFromJson(json['discount_amount']),
      influencedGross: _doubleFromJson(json['influenced_gross']),
      influencedNet: _doubleFromJson(json['influenced_net']),
    );
  }
}

class DiscountBeneficiaryPage {
  const DiscountBeneficiaryPage({
    required this.beneficiaries,
    required this.hasMore,
  });

  final List<DiscountBeneficiary> beneficiaries;
  final bool hasMore;

  factory DiscountBeneficiaryPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(DiscountBeneficiary.fromJson)
        .toList(growable: false);
    return DiscountBeneficiaryPage(
      beneficiaries: results,
      hasMore: json['next'] != null,
    );
  }
}

class DiscountBeneficiary {
  const DiscountBeneficiary({
    required this.id,
    required this.partyType,
    required this.partyId,
    required this.name,
    required this.secondary,
    required this.channel,
    required this.redemptionCount,
    required this.documentCount,
    required this.discountAmount,
    required this.influencedGross,
    required this.influencedNet,
    required this.firstRedeemedAt,
    required this.lastRedeemedAt,
  });

  final String id;
  final String partyType;
  final int? partyId;
  final String name;
  final String secondary;
  final DiscountChannel channel;
  final int redemptionCount;
  final int documentCount;
  final double discountAmount;
  final double influencedGross;
  final double influencedNet;
  final DateTime? firstRedeemedAt;
  final DateTime? lastRedeemedAt;

  factory DiscountBeneficiary.fromJson(Map<String, Object?> json) {
    return DiscountBeneficiary(
      id: json['id']?.toString() ?? '',
      partyType: json['party_type']?.toString() ?? '',
      partyId: _nullableIntFromJson(json['party_id']),
      name: json['name']?.toString() ?? '',
      secondary: json['secondary']?.toString() ?? '',
      channel: DiscountChannel.fromApi(json['channel']?.toString() ?? ''),
      redemptionCount: _intFromJson(json['redemption_count']),
      documentCount: _intFromJson(json['document_count']),
      discountAmount: _doubleFromJson(json['discount_amount']),
      influencedGross: _doubleFromJson(json['influenced_gross']),
      influencedNet: _doubleFromJson(json['influenced_net']),
      firstRedeemedAt: _dateTimeFromJson(json['first_redeemed_at']),
      lastRedeemedAt: _dateTimeFromJson(json['last_redeemed_at']),
    );
  }
}

class DiscountRule {
  const DiscountRule({
    required this.id,
    required this.name,
    required this.description,
    required this.channel,
    required this.applicationType,
    required this.couponCode,
    required this.scope,
    required this.valueType,
    required this.value,
    required this.groupSize,
    required this.buyQuantity,
    required this.getQuantity,
    required this.rewardType,
    required this.tiers,
    required this.maxDiscountAmount,
    required this.roundingMode,
    required this.roundingIncrement,
    required this.minOrderSubtotal,
    required this.minLineQuantity,
    required this.priority,
    required this.exclusive,
    required this.isActive,
    required this.startsAt,
    required this.endsAt,
    required this.usageLimit,
    required this.perCustomerUsageLimit,
    required this.perSupplierUsageLimit,
    required this.products,
    required this.variants,
    required this.productCategories,
    required this.customers,
    required this.customerRanks,
    required this.suppliers,
    required this.metadata,
    required this.redemptionCount,
    required this.appliedCount,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String name;
  final String description;
  final DiscountChannel channel;
  final DiscountApplicationType applicationType;
  final String couponCode;
  final DiscountScope scope;
  final DiscountValueType valueType;
  final double value;
  final int? groupSize;
  final int? buyQuantity;
  final int? getQuantity;
  final DiscountBuyGetReward? rewardType;
  final List<DiscountTier> tiers;
  final double? maxDiscountAmount;
  final DiscountRoundingMode roundingMode;
  final double? roundingIncrement;
  final double minOrderSubtotal;
  final int? minLineQuantity;
  final int priority;
  final bool exclusive;
  final bool isActive;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int? usageLimit;
  final int? perCustomerUsageLimit;
  final int? perSupplierUsageLimit;
  final List<int> products;
  final List<int> variants;
  final List<int> productCategories;
  final List<int> customers;

  /// RFM ranks this rule targets; empty means it applies to every rank.
  final List<CustomerRank> customerRanks;
  final List<int> suppliers;
  final Map<String, Object?> metadata;
  final int redemptionCount;
  final int appliedCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory DiscountRule.fromJson(Map<String, Object?> json) {
    return DiscountRule(
      id: _intFromJson(json['id']),
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      channel: DiscountChannel.fromApi(json['channel']?.toString() ?? ''),
      applicationType: DiscountApplicationType.fromApi(
        json['application_type']?.toString() ?? '',
      ),
      couponCode: json['coupon_code']?.toString() ?? '',
      scope: DiscountScope.fromApi(json['scope']?.toString() ?? ''),
      valueType: DiscountValueType.fromApi(
        json['value_type']?.toString() ?? '',
      ),
      value: _doubleFromJson(json['value']),
      groupSize: _nullableIntFromJson(json['group_size']),
      buyQuantity: _nullableIntFromJson(json['buy_quantity']),
      getQuantity: _nullableIntFromJson(json['get_quantity']),
      rewardType: _rewardTypeFromJson(json['reward_type']),
      tiers: _tierListFromJson(json['tiers']),
      maxDiscountAmount: _nullableDoubleFromJson(json['max_discount_amount']),
      roundingMode: DiscountRoundingMode.fromApi(
        json['rounding_mode']?.toString() ?? '',
      ),
      roundingIncrement: _nullableDoubleFromJson(json['rounding_increment']),
      minOrderSubtotal: _doubleFromJson(json['min_order_subtotal']),
      minLineQuantity: _nullableIntFromJson(json['min_line_quantity']),
      priority: _intFromJson(json['priority']),
      exclusive: json['exclusive'] != false,
      isActive: json['is_active'] != false,
      startsAt: _dateTimeFromJson(json['starts_at']),
      endsAt: _dateTimeFromJson(json['ends_at']),
      usageLimit: _nullableIntFromJson(json['usage_limit']),
      perCustomerUsageLimit: _nullableIntFromJson(
        json['per_customer_usage_limit'],
      ),
      perSupplierUsageLimit: _nullableIntFromJson(
        json['per_supplier_usage_limit'],
      ),
      products: _intListFromJson(json['products']),
      variants: _intListFromJson(json['variants'] ?? json['product_variants']),
      productCategories: _intListFromJson(json['product_categories']),
      customers: _intListFromJson(json['customers']),
      customerRanks: _rankListFromJson(json['customer_ranks']),
      suppliers: _intListFromJson(json['suppliers']),
      metadata: json['metadata'] is Map<String, Object?>
          ? Map<String, Object?>.from(json['metadata']! as Map)
          : const {},
      redemptionCount: _intFromJson(json['redemption_count']),
      appliedCount: _intFromJson(json['applied_count']),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }

  bool get isArchived => metadata['archived_at'] != null;
}

class DiscountRuleDraft {
  const DiscountRuleDraft({
    required this.name,
    required this.description,
    required this.channel,
    required this.applicationType,
    required this.couponCode,
    required this.scope,
    required this.valueType,
    required this.value,
    required this.groupSize,
    required this.buyQuantity,
    required this.getQuantity,
    required this.rewardType,
    required this.tiers,
    required this.maxDiscountAmount,
    required this.roundingMode,
    required this.roundingIncrement,
    required this.minOrderSubtotal,
    required this.minLineQuantity,
    required this.priority,
    required this.exclusive,
    required this.isActive,
    required this.startsAt,
    required this.endsAt,
    required this.usageLimit,
    required this.perCustomerUsageLimit,
    required this.perSupplierUsageLimit,
    required this.products,
    required this.variants,
    required this.productCategories,
    required this.customers,
    required this.customerRanks,
    required this.suppliers,
    this.metadata = const {},
  });

  final String name;
  final String description;
  final DiscountChannel channel;
  final DiscountApplicationType applicationType;
  final String couponCode;
  final DiscountScope scope;
  final DiscountValueType valueType;
  final String value;
  final String groupSize;
  final String buyQuantity;
  final String getQuantity;
  final DiscountBuyGetReward? rewardType;
  final List<DiscountTier> tiers;
  final String maxDiscountAmount;
  final DiscountRoundingMode roundingMode;
  final String roundingIncrement;
  final String minOrderSubtotal;
  final String minLineQuantity;
  final String priority;
  final bool exclusive;
  final bool isActive;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String usageLimit;
  final String perCustomerUsageLimit;
  final String perSupplierUsageLimit;
  final List<int> products;
  final List<int> variants;
  final List<int> productCategories;
  final List<int> customers;
  final List<CustomerRank> customerRanks;
  final List<int> suppliers;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() {
    final normalizedCouponCode = couponCode.trim().toUpperCase();
    return {
      'name': name.trim(),
      'description': description.trim(),
      'channel': channel.apiValue,
      'application_type': applicationType.apiValue,
      'coupon_code': applicationType == DiscountApplicationType.couponCode
          ? normalizedCouponCode
          : '',
      'scope': scope.apiValue,
      'value_type': valueType.apiValue,
      // Tiered rules derive their value from the cheapest tier, so an empty
      // value is sent as null rather than a blank string the API would reject.
      'value': _nullableDecimal(value),
      'group_size': _nullableInt(groupSize),
      'buy_quantity': _nullableInt(buyQuantity),
      'get_quantity': _nullableInt(getQuantity),
      'reward_type': rewardType?.apiValue ?? '',
      'tiers': [
        for (final tier in tiers)
          {
            'min_quantity': tier.minQuantity,
            'unit_price': tier.unitPrice.toStringAsFixed(4),
          },
      ],
      'max_discount_amount': _nullableDecimal(maxDiscountAmount),
      'rounding_mode': roundingMode.apiValue,
      'rounding_increment': roundingMode == DiscountRoundingMode.none
          ? null
          : _nullableDecimal(roundingIncrement),
      'min_order_subtotal': minOrderSubtotal.trim().isEmpty
          ? '0.00'
          : minOrderSubtotal.trim(),
      'min_line_quantity': _nullableInt(minLineQuantity),
      'priority': int.tryParse(priority.trim()) ?? 100,
      'exclusive': exclusive,
      'is_active': isActive,
      'starts_at': startsAt?.toIso8601String(),
      'ends_at': endsAt?.toIso8601String(),
      'usage_limit': _nullableInt(usageLimit),
      'per_customer_usage_limit': _nullableInt(perCustomerUsageLimit),
      'per_supplier_usage_limit': _nullableInt(perSupplierUsageLimit),
      'products': products,
      'variants': variants,
      'product_categories': productCategories,
      'customers': customers,
      'customer_ranks': [for (final rank in customerRanks) rank.apiValue],
      'suppliers': suppliers,
      'metadata': metadata,
    };
  }
}

double _doubleFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

double? _nullableDoubleFromJson(Object? value) {
  if (value == null || value.toString().isEmpty) {
    return null;
  }
  return _doubleFromJson(value);
}

int _intFromJson(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null || value.toString().isEmpty) {
    return null;
  }
  return _intFromJson(value);
}

List<int> _intListFromJson(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  return value
      .map(_nullableIntFromJson)
      .whereType<int>()
      .toList(growable: false);
}

DiscountBuyGetReward? _rewardTypeFromJson(Object? value) {
  final raw = value?.toString() ?? '';
  return raw.isEmpty ? null : DiscountBuyGetReward.fromApi(raw);
}

List<DiscountTier> _tierListFromJson(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  return value
      .whereType<Map<String, Object?>>()
      .map(DiscountTier.fromJson)
      .toList(growable: false);
}

List<CustomerRank> _rankListFromJson(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  return value
      .map((entry) => CustomerRank.fromApi(entry?.toString() ?? ''))
      .toList(growable: false);
}

Map<String, Object?> _mapFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  return const {};
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null || value.toString().isEmpty) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

String? _nullableDecimal(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

int? _nullableInt(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? null : int.tryParse(normalized);
}
