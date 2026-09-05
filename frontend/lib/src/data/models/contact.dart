import 'query.dart';

enum ContactStatusFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false')),
  // Placeholder customers minted from captured cards. The list hides them by
  // default; this opts back in via ?is_auto_created=true.
  unclaimedCards(QueryFilter(parameter: 'is_auto_created', value: 'true'));

  const ContactStatusFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum ContactOrdering implements QueryOrdering {
  name('full_name'),
  newest('-created_at'),
  updated('-updated_at');

  const ContactOrdering(this.apiValue);

  @override
  final String apiValue;
}

/// How much a customer is allowed to owe on آجل invoices. Mirrors the backend
/// ``Customer.CreditLimitPolicy``. Three states because all three are things an
/// owner says: follow the shop, never cap this one, or use this exact number
/// (including 0 — "this one pays cash").
enum CreditLimitPolicy {
  shopDefault('shop_default'),
  unlimited('unlimited'),
  custom('custom');

  const CreditLimitPolicy(this.apiValue);

  final String apiValue;

  static CreditLimitPolicy fromApi(String value) {
    return CreditLimitPolicy.values.firstWhere(
      (policy) => policy.apiValue == value,
      orElse: () => CreditLimitPolicy.shopDefault,
    );
  }
}

/// RFM segment a customer falls into, assigned automatically by the backend
/// nightly job. Ordered best → worst; [inactive] means "no recognized purchase
/// yet". The [apiValue] mirrors the backend ``Customer.Rank`` slugs.
enum CustomerRank {
  champion('champion'),
  loyal('loyal'),
  potentialLoyalist('potential_loyalist'),
  newCustomer('new_customer'),
  promising('promising'),
  needsAttention('needs_attention'),
  atRisk('at_risk'),
  cantLose('cant_lose'),
  hibernating('hibernating'),
  lost('lost'),
  inactive('inactive');

  const CustomerRank(this.apiValue);

  final String apiValue;

  static CustomerRank fromApi(String value) {
    return CustomerRank.values.firstWhere(
      (rank) => rank.apiValue == value,
      orElse: () => CustomerRank.inactive,
    );
  }
}

/// Customers-list filter by RFM rank. [all] applies no filter; every other
/// value pins the list to one rank via ``?rfm_segment=<slug>``.
enum CustomerRankFilter implements QueryFilterSet {
  all(null),
  champion(CustomerRank.champion),
  loyal(CustomerRank.loyal),
  potentialLoyalist(CustomerRank.potentialLoyalist),
  newCustomer(CustomerRank.newCustomer),
  promising(CustomerRank.promising),
  needsAttention(CustomerRank.needsAttention),
  atRisk(CustomerRank.atRisk),
  cantLose(CustomerRank.cantLose),
  hibernating(CustomerRank.hibernating),
  lost(CustomerRank.lost),
  inactive(CustomerRank.inactive);

  const CustomerRankFilter(this.rank);

  final CustomerRank? rank;

  @override
  Iterable<QueryFilter> get filters {
    final rank = this.rank;
    return rank == null
        ? const []
        : [QueryFilter(parameter: 'rfm_segment', value: rank.apiValue)];
  }
}

class ContactQuery extends ModelQuery {
  const ContactQuery({
    this.search = '',
    this.status = ContactStatusFilter.all,
    this.rank = CustomerRankFilter.all,
    this.ordering = ContactOrdering.name,
  });

  @override
  final String search;
  final ContactStatusFilter status;
  final CustomerRankFilter rank;
  @override
  final ContactOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [...status.filters, ...rank.filters];

  ContactQuery copyWith({
    String? search,
    ContactStatusFilter? status,
    CustomerRankFilter? rank,
    ContactOrdering? ordering,
  }) {
    return ContactQuery(
      search: search ?? this.search,
      status: status ?? this.status,
      rank: rank ?? this.rank,
      ordering: ordering ?? this.ordering,
    );
  }
}

enum CustomerGender {
  unspecified(''),
  female('female'),
  male('male'),
  nonBinary('non_binary'),
  preferNotToSay('prefer_not_to_say');

  const CustomerGender(this.apiValue);

  final String apiValue;

  static CustomerGender fromApi(String value) {
    return CustomerGender.values.firstWhere(
      (gender) => gender.apiValue == value,
      orElse: () => CustomerGender.unspecified,
    );
  }
}

class CustomerPage {
  const CustomerPage({required this.customers, required this.hasMore});

  final List<Customer> customers;
  final bool hasMore;

  factory CustomerPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(Customer.fromJson)
        .toList(growable: false);
    return CustomerPage(customers: results, hasMore: json['next'] != null);
  }
}

class SupplierPage {
  const SupplierPage({required this.suppliers, required this.hasMore});

  final List<SupplierContact> suppliers;
  final bool hasMore;

  factory SupplierPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(SupplierContact.fromJson)
        .toList(growable: false);
    return SupplierPage(suppliers: results, hasMore: json['next'] != null);
  }
}

class Customer {
  const Customer({
    required this.id,
    required this.customerNumber,
    required this.fullName,
    required this.phone,
    required this.email,
    required this.gender,
    required this.marketingConsent,
    required this.notes,
    required this.isActive,
    this.birthday,
    this.isAutoCreated = false,
    this.cardCount = 0,
    this.rank = CustomerRank.inactive,
    this.rankScore = 0,
    this.totalSpent = 0,
    this.purchaseCount = 0,
    this.recencyDays,
    this.lastPurchaseAt,
    this.marketingOptedOut = false,
    this.doNotContact = false,
    this.creditLimitPolicy = CreditLimitPolicy.shopDefault,
    this.creditLimit,
    this.effectiveCreditLimit,
  });

  final int id;
  final String customerNumber;
  final String fullName;
  final String phone;
  final String email;
  final CustomerGender gender;
  final DateTime? birthday;
  final bool marketingConsent;
  final String notes;
  final bool isActive;

  /// True for placeholder customers minted from a captured card. They stay
  /// hidden from the contacts list until named (claimed) or merged.
  final bool isAutoCreated;

  /// Number of payment cards attached to this customer (server-annotated).
  final int cardCount;

  /// RFM segment assigned by the backend's nightly segmentation job.
  final CustomerRank rank;

  /// Combined RFM score (3–15 once scored, 0 while unscored).
  final int rankScore;

  /// Net recognized spend (committed sales less returns).
  final double totalSpent;

  /// Number of recognized purchases (committed sales).
  final int purchaseCount;

  /// Days since the last recognized purchase (null when none).
  final int? recencyDays;

  /// Timestamp of the last recognized purchase (null when none).
  final DateTime? lastPurchaseAt;

  /// Contact consent (opt-out policy): the customer has opted out of marketing.
  final bool marketingOptedOut;

  /// A hard do-not-contact flag (blocks marketing; transactional still allowed).
  final bool doNotContact;

  /// Which credit ceiling applies to this customer. See [CreditLimitPolicy].
  final CreditLimitPolicy creditLimitPolicy;

  /// This customer's own ceiling. Only meaningful under
  /// [CreditLimitPolicy.custom]; null otherwise.
  final double? creditLimit;

  /// The ceiling that actually applies once the policy and the shop default
  /// have been resolved — computed by the server. Null = no limit.
  final double? effectiveCreditLimit;

  factory Customer.fromJson(Map<String, Object?> json) {
    return Customer(
      id: _intFromJson(json['id']),
      customerNumber: json['customer_number']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      gender: CustomerGender.fromApi(json['gender']?.toString() ?? ''),
      birthday: _dateFromJson(json['birthday']),
      marketingConsent: json['marketing_consent'] == true,
      notes: json['notes']?.toString() ?? '',
      isActive: json['is_active'] != false,
      isAutoCreated: json['is_auto_created'] == true,
      cardCount: _intFromJson(json['card_count']),
      rank: CustomerRank.fromApi(json['rfm_segment']?.toString() ?? ''),
      rankScore: _intFromJson(json['rfm_score']),
      totalSpent: _moneyFromJson(json['rfm_monetary']),
      purchaseCount: _intFromJson(json['rfm_frequency']),
      recencyDays: json['rfm_recency_days'] == null
          ? null
          : _intFromJson(json['rfm_recency_days']),
      lastPurchaseAt: _dateFromJson(json['rfm_last_purchase_at']),
      marketingOptedOut: json['marketing_opted_out'] == true,
      doNotContact: json['do_not_contact'] == true,
      creditLimitPolicy: CreditLimitPolicy.fromApi(
        json['credit_limit_policy']?.toString() ?? '',
      ),
      creditLimit: json['credit_limit'] == null
          ? null
          : _moneyFromJson(json['credit_limit']),
      effectiveCreditLimit: json['effective_credit_limit'] == null
          ? null
          : _moneyFromJson(json['effective_credit_limit']),
    );
  }

  /// Serialization for local persistence (a restored POS cart keeps its
  /// selected customer). Round-trips through [Customer.fromJson].
  Map<String, Object?> toJson() {
    return {
      'id': id,
      'customer_number': customerNumber,
      'full_name': fullName,
      'phone': phone,
      'email': email,
      'gender': gender.apiValue,
      'birthday': birthday?.toIso8601String().split('T').first,
      'marketing_consent': marketingConsent,
      'notes': notes,
      'is_active': isActive,
      'is_auto_created': isAutoCreated,
      'credit_limit_policy': creditLimitPolicy.apiValue,
      'credit_limit': creditLimit,
      'effective_credit_limit': effectiveCreditLimit,
    };
  }
}

class CustomerDraft {
  const CustomerDraft({
    required this.fullName,
    required this.phone,
    required this.email,
    required this.gender,
    required this.birthday,
    required this.marketingConsent,
    required this.notes,
    required this.isActive,
  });

  final String fullName;
  final String phone;
  final String email;
  final CustomerGender gender;
  final DateTime? birthday;
  final bool marketingConsent;
  final String notes;
  final bool isActive;

  Map<String, Object?> toJson() {
    return {
      'full_name': fullName,
      'phone': phone,
      'email': email,
      'gender': gender.apiValue,
      'birthday': birthday?.toIso8601String().split('T').first,
      'marketing_consent': marketingConsent,
      'notes': notes,
      'is_active': isActive,
    };
  }
}

class SupplierContact {
  const SupplierContact({
    required this.id,
    required this.name,
    required this.contactName,
    required this.phone,
    required this.email,
    required this.address,
    required this.notes,
    required this.isActive,
    this.payableBalance = 0,
    this.creditBalance = 0,
    this.netBalance = 0,
    this.totalBought = 0,
    this.purchaseCount = 0,
  });

  final int id;
  final String name;
  final String contactName;
  final String phone;
  final String email;
  final String address;
  final String notes;
  final bool isActive;
  final double payableBalance;
  final double creditBalance;
  final double netBalance;
  final double totalBought;
  final int purchaseCount;

  /// Serialization for local persistence (a restored purchase draft keeps its
  /// selected supplier). Derived balances are intentionally omitted — they go
  /// stale and are recomputed from the server.
  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'contact_name': contactName,
      'phone': phone,
      'email': email,
      'address': address,
      'notes': notes,
      'is_active': isActive,
    };
  }

  factory SupplierContact.fromJson(Map<String, Object?> json) {
    return SupplierContact(
      id: _intFromJson(json['id']),
      name: json['name']?.toString() ?? '',
      contactName: json['contact_name']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      isActive: json['is_active'] != false,
      payableBalance: _moneyFromJson(json['payable_balance']),
      creditBalance: _moneyFromJson(json['credit_balance']),
      netBalance: _moneyFromJson(json['net_balance']),
      totalBought: _moneyFromJson(
        json['total_bought'] ??
            json['total_purchased'] ??
            json['purchase_total'],
      ),
      purchaseCount: _intFromJson(
        json['purchase_count'] ?? json['purchase_order_count'],
      ),
    );
  }
}

class SupplierDraft {
  const SupplierDraft({
    required this.name,
    required this.contactName,
    required this.phone,
    required this.email,
    required this.address,
    required this.notes,
    required this.isActive,
  });

  final String name;
  final String contactName;
  final String phone;
  final String email;
  final String address;
  final String notes;
  final bool isActive;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'contact_name': contactName,
      'phone': phone,
      'email': email,
      'address': address,
      'notes': notes,
      'is_active': isActive,
    };
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

DateTime? _dateFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
