import 'query.dart';

enum ContactStatusFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false'));

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

class ContactQuery extends ModelQuery {
  const ContactQuery({
    this.search = '',
    this.status = ContactStatusFilter.all,
    this.ordering = ContactOrdering.name,
  });

  @override
  final String search;
  final ContactStatusFilter status;
  @override
  final ContactOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => status.filters;

  ContactQuery copyWith({
    String? search,
    ContactStatusFilter? status,
    ContactOrdering? ordering,
  }) {
    return ContactQuery(
      search: search ?? this.search,
      status: status ?? this.status,
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
    );
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
