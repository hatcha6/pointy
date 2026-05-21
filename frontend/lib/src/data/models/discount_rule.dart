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
  fixedPrice('fixed_price');

  const DiscountValueType(this.apiValue);

  final String apiValue;

  static DiscountValueType fromApi(String value) {
    return DiscountValueType.values.firstWhere(
      (type) => type.apiValue == value,
      orElse: () => DiscountValueType.percentage,
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
    required this.maxDiscountAmount,
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
    required this.productCategories,
    required this.customers,
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
  final double? maxDiscountAmount;
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
  final List<int> productCategories;
  final List<int> customers;
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
      maxDiscountAmount: _nullableDoubleFromJson(json['max_discount_amount']),
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
      productCategories: _intListFromJson(json['product_categories']),
      customers: _intListFromJson(json['customers']),
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
    required this.maxDiscountAmount,
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
    required this.productCategories,
    required this.customers,
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
  final String maxDiscountAmount;
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
  final List<int> productCategories;
  final List<int> customers;
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
      'value': value.trim(),
      'max_discount_amount': _nullableDecimal(maxDiscountAmount),
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
      'product_categories': productCategories,
      'customers': customers,
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
