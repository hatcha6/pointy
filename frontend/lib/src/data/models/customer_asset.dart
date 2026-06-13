enum CustomerAssetType {
  phone,
  tablet,
  laptop,
  console,
  appliance,
  other;

  static CustomerAssetType fromJson(Object? value) {
    return switch (value?.toString()) {
      'phone' => CustomerAssetType.phone,
      'tablet' => CustomerAssetType.tablet,
      'laptop' => CustomerAssetType.laptop,
      'console' => CustomerAssetType.console,
      'appliance' => CustomerAssetType.appliance,
      _ => CustomerAssetType.other,
    };
  }

  String toJson() => name;
}

class CustomerAsset {
  const CustomerAsset({
    required this.id,
    required this.customer,
    required this.customerName,
    required this.assetType,
    required this.brand,
    required this.modelName,
    required this.serialNumber,
    required this.imei,
    required this.color,
    required this.notes,
    required this.displayName,
    required this.jobCount,
    required this.isActive,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int customer;
  final String customerName;
  final CustomerAssetType assetType;
  final String brand;
  final String modelName;
  final String serialNumber;
  final String imei;
  final String color;
  final String notes;
  final String displayName;
  final int jobCount;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory CustomerAsset.fromJson(Map<String, Object?> json) {
    return CustomerAsset(
      id: json['id'] as int,
      customer: _intFromJson(json['customer']),
      customerName: json['customer_name']?.toString() ?? '',
      assetType: CustomerAssetType.fromJson(json['asset_type']),
      brand: json['brand']?.toString() ?? '',
      modelName: json['model_name']?.toString() ?? '',
      serialNumber: json['serial_number']?.toString() ?? '',
      imei: json['imei']?.toString() ?? '',
      color: json['color']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      jobCount: _intFromJson(json['job_count']),
      isActive: json['is_active'] == true,
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class CustomerAssetPage {
  const CustomerAssetPage({required this.assets, required this.hasMore});

  final List<CustomerAsset> assets;
  final bool hasMore;

  factory CustomerAssetPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(CustomerAsset.fromJson)
        .toList(growable: false);

    return CustomerAssetPage(assets: results, hasMore: json['next'] != null);
  }
}

class CustomerAssetDraft {
  const CustomerAssetDraft({
    required this.customer,
    required this.assetType,
    this.brand = '',
    this.modelName = '',
    this.serialNumber = '',
    this.imei = '',
    this.color = '',
    this.notes = '',
  });

  final int customer;
  final CustomerAssetType assetType;
  final String brand;
  final String modelName;
  final String serialNumber;
  final String imei;
  final String color;
  final String notes;

  Map<String, Object?> toJson() {
    return {
      'customer': customer,
      'asset_type': assetType.toJson(),
      'brand': brand,
      'model_name': modelName,
      'serial_number': serialNumber,
      'imei': imei,
      'color': color,
      'notes': notes,
    };
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
