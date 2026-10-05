import 'identified_stock_settings.dart' show BatchPickStrategy;
import 'tracking_mode.dart';

/// Everything a product says about how its stock is identified — the mode,
/// and the facts each mode reads.
///
/// One value for the create form, the edit sheet and a carried-over run of
/// products, so the three cannot disagree about which fields travel together:
/// a lot policy is meaningless without a lot mode, a warranty without articles.
class ProductTracking {
  const ProductTracking({
    this.mode = TrackingMode.quantity,
    this.assetTypeId,
    this.warrantyDays = 0,
    this.shelfLifeDays = 0,
    this.expiryWarningDays = 30,
    this.autoPickStrategy = BatchPickStrategy.fefo,
    this.preventSellingExpired = true,
    this.expiryRequired = false,
  });

  final TrackingMode mode;

  /// What kind of identified thing this is — a phone, a vehicle — which
  /// decides what its identifier is called. Read for serial modes only.
  final int? assetTypeId;

  /// Warranty granted on sale, stamped onto the article when it sells. 0 is
  /// none. Read for serial modes only.
  final int warrantyDays;

  /// How long a lot keeps from the day it arrives, so receiving can propose an
  /// expiry. 0 is "no fixed shelf life". Read for lot modes only.
  final int shelfLifeDays;

  /// How many days before a lot expires the shop is warned.
  final int expiryWarningDays;

  /// Which lot leaves first when the cashier names none.
  final BatchPickStrategy autoPickStrategy;

  /// Refuse to sell a lot past its date. The shop-wide switch is a floor under
  /// this: a product may be stricter than the shop, never laxer.
  final bool preventSellingExpired;

  /// Receiving must name each lot's expiry date. Read for lot modes only: a
  /// run of phone cases is lot-tracked for provenance and never goes off.
  final bool expiryRequired;

  ProductTracking copyWith({
    TrackingMode? mode,
    Object? assetTypeId = _keep,
    int? warrantyDays,
    int? shelfLifeDays,
    int? expiryWarningDays,
    BatchPickStrategy? autoPickStrategy,
    bool? preventSellingExpired,
    bool? expiryRequired,
  }) {
    return ProductTracking(
      mode: mode ?? this.mode,
      assetTypeId: identical(assetTypeId, _keep)
          ? this.assetTypeId
          : assetTypeId as int?,
      warrantyDays: warrantyDays ?? this.warrantyDays,
      shelfLifeDays: shelfLifeDays ?? this.shelfLifeDays,
      expiryWarningDays: expiryWarningDays ?? this.expiryWarningDays,
      autoPickStrategy: autoPickStrategy ?? this.autoPickStrategy,
      preventSellingExpired:
          preventSellingExpired ?? this.preventSellingExpired,
      expiryRequired: expiryRequired ?? this.expiryRequired,
    );
  }

  /// The product's write fields. `tracks_expiry` rides along, derived, for a
  /// server that predates the mode: one that knows the mode ignores it.
  Map<String, Object?> toJson() {
    return {
      'tracking_mode': mode.wire,
      'tracks_expiry': mode.tracksLots,
      'asset_type': assetTypeId,
      'warranty_days': warrantyDays,
      'shelf_life_days': shelfLifeDays,
      'expiry_warning_days': expiryWarningDays,
      'auto_pick_strategy': autoPickStrategy.wire,
      'prevent_selling_expired': preventSellingExpired,
      'expiry_required': expiryRequired,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is ProductTracking &&
        other.mode == mode &&
        other.assetTypeId == assetTypeId &&
        other.warrantyDays == warrantyDays &&
        other.shelfLifeDays == shelfLifeDays &&
        other.expiryWarningDays == expiryWarningDays &&
        other.autoPickStrategy == autoPickStrategy &&
        other.preventSellingExpired == preventSellingExpired &&
        other.expiryRequired == expiryRequired;
  }

  @override
  int get hashCode => Object.hash(
    mode,
    assetTypeId,
    warrantyDays,
    shelfLifeDays,
    expiryWarningDays,
    autoPickStrategy,
    preventSellingExpired,
    expiryRequired,
  );
}

const Object _keep = Object();
