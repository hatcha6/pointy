enum CustomerAssetType {
  phone,
  tablet,
  laptop,
  console,
  appliance,
  vehicle,
  other;

  static CustomerAssetType fromJson(Object? value) {
    return switch (value?.toString()) {
      'phone' => CustomerAssetType.phone,
      'tablet' => CustomerAssetType.tablet,
      'laptop' => CustomerAssetType.laptop,
      'console' => CustomerAssetType.console,
      'appliance' => CustomerAssetType.appliance,
      'vehicle' => CustomerAssetType.vehicle,
      _ => CustomerAssetType.other,
    };
  }

  String toJson() => name;

  /// Whether this kind of item is identified by plate and chassis rather than
  /// by IMEI and serial. Drives which identity fields the intake form shows.
  bool get isVehicle => this == CustomerAssetType.vehicle;
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
    this.customerPhone = '',
    this.vin = '',
    this.plateNumber = '',
    this.engineNumber = '',
    this.modelYear,
    this.odometer,
    this.identityLabel = '',
    this.openJobCount = 0,
    this.lastJobAt,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int customer;
  final String customerName;
  final String customerPhone;
  final CustomerAssetType assetType;
  final String brand;
  final String modelName;
  final String serialNumber;
  final String imei;
  final String vin;
  final String plateNumber;
  final String engineNumber;
  final int? modelYear;
  final int? odometer;
  final String color;
  final String notes;
  final String displayName;

  /// The number a person would quote to find this item again — plate first for
  /// a vehicle, then chassis, then the phone identifiers.
  final String identityLabel;
  final int jobCount;

  /// How many jobs on this item are still open: non-zero means it is physically
  /// in the shop right now.
  final int openJobCount;
  final DateTime? lastJobAt;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isInShop => openJobCount > 0;

  factory CustomerAsset.fromJson(Map<String, Object?> json) {
    return CustomerAsset(
      id: json['id'] as int,
      customer: _intFromJson(json['customer']),
      customerName: json['customer_name']?.toString() ?? '',
      customerPhone: json['customer_phone']?.toString() ?? '',
      assetType: CustomerAssetType.fromJson(json['asset_type']),
      brand: json['brand']?.toString() ?? '',
      modelName: json['model_name']?.toString() ?? '',
      serialNumber: json['serial_number']?.toString() ?? '',
      imei: json['imei']?.toString() ?? '',
      vin: json['vin']?.toString() ?? '',
      plateNumber: json['plate_number']?.toString() ?? '',
      engineNumber: json['engine_number']?.toString() ?? '',
      modelYear: _nullableIntFromJson(json['model_year']),
      odometer: _nullableIntFromJson(json['odometer']),
      color: json['color']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      identityLabel: json['identity_label']?.toString() ?? '',
      jobCount: _intFromJson(json['job_count']),
      openJobCount: _intFromJson(json['open_job_count']),
      lastJobAt: _dateTimeFromJson(json['last_job_at']),
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
    this.vin = '',
    this.plateNumber = '',
    this.engineNumber = '',
    this.modelYear,
    this.odometer,
    this.color = '',
    this.notes = '',
  });

  final int customer;
  final CustomerAssetType assetType;
  final String brand;
  final String modelName;
  final String serialNumber;
  final String imei;
  final String vin;
  final String plateNumber;
  final String engineNumber;
  final int? modelYear;
  final int? odometer;
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
      'vin': vin,
      'plate_number': plateNumber,
      'engine_number': engineNumber,
      'model_year': modelYear,
      'odometer': odometer,
      'color': color,
      'notes': notes,
    };
  }
}

/// One stretch of time an item belonged to one customer.
///
/// The open row (no [releasedAt]) is the current owner. Closed rows are how the
/// shop can tell a buyer "the previous owner had the gearbox done here".
class AssetOwnership {
  const AssetOwnership({
    required this.id,
    required this.customer,
    required this.customerName,
    required this.customerPhone,
    required this.isCurrent,
    required this.note,
    this.acquiredAt,
    this.releasedAt,
  });

  final int id;
  final int customer;
  final String customerName;
  final String customerPhone;
  final bool isCurrent;
  final String note;
  final DateTime? acquiredAt;
  final DateTime? releasedAt;

  factory AssetOwnership.fromJson(Map<String, Object?> json) {
    return AssetOwnership(
      id: json['id'] as int,
      customer: _intFromJson(json['customer']),
      customerName: json['customer_name']?.toString() ?? '',
      customerPhone: json['customer_phone']?.toString() ?? '',
      isCurrent: json['is_current'] == true,
      note: json['note']?.toString() ?? '',
      acquiredAt: _dateTimeFromJson(json['acquired_at']),
      releasedAt: _dateTimeFromJson(json['released_at']),
    );
  }
}

/// One visit in an item's service history, read from the item's side.
class AssetJobHistoryEntry {
  const AssetJobHistoryEntry({
    required this.id,
    required this.jobNumber,
    required this.jobType,
    required this.status,
    required this.stageName,
    required this.customerName,
    required this.symptoms,
    required this.diagnosis,
    required this.warrantyDays,
    required this.orderReceiptNumber,
    this.total,
    this.createdAt,
    this.completedAt,
    this.handedOverAt,
  });

  final int id;
  final String jobNumber;
  final String jobType;
  final String status;
  final String stageName;
  final String customerName;
  final String symptoms;
  final String diagnosis;
  final int warrantyDays;
  final String orderReceiptNumber;
  final double? total;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final DateTime? handedOverAt;

  bool get isOpen => status == 'open';

  factory AssetJobHistoryEntry.fromJson(Map<String, Object?> json) {
    return AssetJobHistoryEntry(
      id: json['id'] as int,
      jobNumber: json['job_number']?.toString() ?? '',
      jobType: json['job_type']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      stageName: json['stage_name']?.toString() ?? '',
      customerName: json['customer_name']?.toString() ?? '',
      symptoms: json['symptoms']?.toString() ?? '',
      diagnosis: json['diagnosis']?.toString() ?? '',
      warrantyDays: _intFromJson(json['warranty_days']),
      orderReceiptNumber: json['order_receipt_number']?.toString() ?? '',
      total: json['total'] == null
          ? null
          : double.tryParse(json['total'].toString()),
      createdAt: _dateTimeFromJson(json['created_at']),
      completedAt: _dateTimeFromJson(json['completed_at']),
      handedOverAt: _dateTimeFromJson(json['handed_over_at']),
    );
  }
}

/// An asset with everything the details screen shows: who owns it, who owned it
/// before, and every job the shop has done to it.
class CustomerAssetDetail {
  const CustomerAssetDetail({
    required this.asset,
    required this.ownerships,
    required this.jobs,
    required this.totalSpent,
  });

  final CustomerAsset asset;
  final List<AssetOwnership> ownerships;
  final List<AssetJobHistoryEntry> jobs;
  final double totalSpent;

  factory CustomerAssetDetail.fromJson(Map<String, Object?> json) {
    final ownershipsJson = (json['ownerships'] as List<Object?>?) ?? const [];
    final jobsJson = (json['jobs'] as List<Object?>?) ?? const [];
    return CustomerAssetDetail(
      asset: CustomerAsset.fromJson(json),
      ownerships: ownershipsJson
          .whereType<Map<String, Object?>>()
          .map(AssetOwnership.fromJson)
          .toList(growable: false),
      jobs: jobsJson
          .whereType<Map<String, Object?>>()
          .map(AssetJobHistoryEntry.fromJson)
          .toList(growable: false),
      totalSpent: double.tryParse(json['total_spent']?.toString() ?? '') ?? 0,
    );
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
