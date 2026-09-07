import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// A place the shop keeps stock.
///
/// Flat on purpose — there is no parent, no group, no tree. A shop has a
/// showroom, perhaps a store room, perhaps a van. Most shops have only the
/// first and never open a second, which is why nothing in the app pushes them
/// towards one.
class Warehouse {
  const Warehouse({
    required this.id,
    required this.name,
    required this.code,
    this.kind = WarehouseKind.shopFloor,
    this.oversellPolicy = WarehouseOversellPolicy.shopDefault,
    this.isDefault = false,
    this.isActive = true,
    this.stockItemCount = 0,
    this.blockers = const <String>[],
    this.canDelete = true,
  });

  final int id;
  final String name;
  final String code;
  final WarehouseKind kind;
  final WarehouseOversellPolicy oversellPolicy;

  /// The shop's original location. Cannot be deleted, and is where everything
  /// lands that does not say otherwise.
  final bool isDefault;
  final bool isActive;

  /// How many products hold stock here — the "what is in this room" figure the
  /// list shows so the card is worth reading.
  final int stockItemCount;

  /// Why this place cannot be deleted, straight from the server. Shown instead
  /// of offering a button that would fail.
  final List<String> blockers;
  final bool canDelete;

  /// Goods on the road are not a room anyone sells from.
  bool get sellsFrom => kind != WarehouseKind.transit;

  factory Warehouse.fromJson(Map<String, Object?> json) {
    return Warehouse(
      id: (json['id'] as num).toInt(),
      name: json['name']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      kind: warehouseKindFromValue(json['kind']?.toString()),
      oversellPolicy: warehouseOversellPolicyFromValue(
        json['allow_overselling']?.toString(),
      ),
      isDefault: json['is_default'] == true,
      isActive: json['is_active'] != false,
      stockItemCount: (json['stock_item_count'] as num?)?.toInt() ?? 0,
      blockers: (json['blockers'] as List<Object?>? ?? const <Object?>[])
          .map((entry) => entry.toString())
          .toList(growable: false),
      canDelete: json['can_delete'] == true,
    );
  }

  Map<String, Object?> toCreateJson() {
    return <String, Object?>{
      'name': name,
      'code': code,
      'kind': kind.wireValue,
      'allow_overselling': oversellPolicy.wireValue,
      'is_active': isActive,
    };
  }

  Warehouse copyWith({
    String? name,
    String? code,
    WarehouseKind? kind,
    WarehouseOversellPolicy? oversellPolicy,
    bool? isActive,
  }) {
    return Warehouse(
      id: id,
      name: name ?? this.name,
      code: code ?? this.code,
      kind: kind ?? this.kind,
      oversellPolicy: oversellPolicy ?? this.oversellPolicy,
      isDefault: isDefault,
      isActive: isActive ?? this.isActive,
      stockItemCount: stockItemCount,
      blockers: blockers,
      canDelete: canDelete,
    );
  }
}

/// What kind of place this is. Not permissions and not a hierarchy — it exists
/// so the app can say "المعرض" rather than "مخزن ٣", and so a transfer knows
/// which rooms are real destinations.
enum WarehouseKind {
  shopFloor('shop_floor'),
  storeRoom('store_room'),
  van('van'),
  transit('transit');

  const WarehouseKind(this.wireValue);

  final String wireValue;
}

WarehouseKind warehouseKindFromValue(String? value) {
  return WarehouseKind.values.firstWhere(
    (kind) => kind.wireValue == value,
    orElse: () => WarehouseKind.shopFloor,
  );
}

/// Whether this room may go below zero, or follows whatever the shop says.
enum WarehouseOversellPolicy {
  shopDefault('shop_default'),
  allow('allow'),
  refuse('refuse');

  const WarehouseOversellPolicy(this.wireValue);

  final String wireValue;
}

WarehouseOversellPolicy warehouseOversellPolicyFromValue(String? value) {
  return WarehouseOversellPolicy.values.firstWhere(
    (policy) => policy.wireValue == value,
    orElse: () => WarehouseOversellPolicy.shopDefault,
  );
}

/// How much of one product sits in one place.
class WarehouseStockRow {
  const WarehouseStockRow({
    required this.warehouseId,
    required this.warehouseName,
    required this.kind,
    required this.quantityOnHand,
    this.quantityCommitted = 0,
    this.quantityExpected = 0,
  });

  final int warehouseId;
  final String warehouseName;
  final WarehouseKind kind;
  final double quantityOnHand;
  final double quantityCommitted;
  final double quantityExpected;

  factory WarehouseStockRow.fromJson(Map<String, Object?> json) {
    double number(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
    return WarehouseStockRow(
      warehouseId: (json['warehouse'] as num?)?.toInt() ?? 0,
      warehouseName: json['warehouse_name']?.toString() ?? '',
      kind: warehouseKindFromValue(json['warehouse_kind']?.toString()),
      quantityOnHand: number(json['quantity_on_hand']),
      quantityCommitted: number(json['quantity_committed']),
      quantityExpected: number(json['quantity_expected']),
    );
  }
}

/// What one till is set up to do. Today: which place it sells out of.
class RegisterProfile {
  const RegisterProfile({
    required this.warehouseId,
    required this.warehouseName,
    this.kind = WarehouseKind.shopFloor,
    this.deviceId = '',
    this.name = '',
    this.assigned = false,
  });

  final int warehouseId;
  final String warehouseName;
  final WarehouseKind kind;
  final String deviceId;
  final String name;

  /// False when the backend has no row for this device — an older client, or
  /// one that does not identify itself. It still gets a warehouse (the shop's
  /// default), because a till must never be unable to sell.
  final bool assigned;

  factory RegisterProfile.fromJson(Map<String, Object?> json) {
    return RegisterProfile(
      warehouseId: (json['warehouse'] as num?)?.toInt() ?? 0,
      warehouseName: json['warehouse_name']?.toString() ?? '',
      kind: warehouseKindFromValue(json['warehouse_kind']?.toString()),
      deviceId: json['device_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      assigned: json['assigned'] == true,
    );
  }
}

extension WarehouseKindLabel on WarehouseKind {
  String label(AppLocalizations l10n) {
    switch (this) {
      case WarehouseKind.shopFloor:
        return l10n.warehouseKindShopFloor;
      case WarehouseKind.storeRoom:
        return l10n.warehouseKindStoreRoom;
      case WarehouseKind.van:
        return l10n.warehouseKindVan;
      case WarehouseKind.transit:
        return l10n.warehouseKindTransit;
    }
  }
}
