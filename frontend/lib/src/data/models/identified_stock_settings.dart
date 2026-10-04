import 'consignment.dart' show ConsignmentLiability;

/// How a product's lots are picked at the till when the cashier names none.
enum BatchPickStrategy {
  /// The lot that goes off first leaves first. What a pharmacy means.
  fefo('fefo'),

  /// The lot that arrived first leaves first, whatever its date says.
  fifo('fifo'),

  /// Nothing is picked for the cashier. Product-level only: the shop-wide
  /// default is always one of the automatic two.
  manual('manual');

  const BatchPickStrategy(this.wire);

  final String wire;

  static BatchPickStrategy fromWire(Object? value) {
    final text = value?.toString() ?? '';
    for (final strategy in BatchPickStrategy.values) {
      if (strategy.wire == text) {
        return strategy;
      }
    }
    return BatchPickStrategy.fefo;
  }
}

/// The shop-wide switches for identified stock — serials, lots, and goods
/// held on consignment.
///
/// Both master switches are off by default, and that default is the feature's
/// whole contract: a shop that sells Coca-Cola must not be able to tell that
/// serialization and batch tracking shipped. They gate the *surfaces*; how a
/// product actually behaves is its own tracking mode.
///
/// Kept apart from [ShopSettingsDraft] on purpose. That draft is sent whole,
/// so every field added to it is a field the main settings form could reset by
/// forgetting it. This one is saved by its own page as a partial update that
/// names only these keys.
class IdentifiedStockSettings {
  const IdentifiedStockSettings({
    this.enableSerializedInventory = false,
    this.enableBatchTracking = false,
    this.captureLaterAllowed = false,
    this.requireCustomerForAsset = true,
    this.preventSellingExpiredBatches = true,
    this.batchAutoPickStrategy = BatchPickStrategy.fefo,
    this.defaultExpiryWarningDays = 30,
    this.consignmentAutoSmsOnSale = true,
    this.consignmentDefaultLiabilityPolicy = ConsignmentLiability.ownerRisk,
    this.consignmentClauseOwnerRisk = '',
    this.consignmentClauseShopLiableExceptForceMajeure = '',
    this.consignmentClauseShopLiable = '',
    this.consignmentRequireDeclaredValue = true,
    this.consignmentUnclaimedPayoutReminderDays = 30,
  });

  factory IdentifiedStockSettings.fromJson(Map<String, Object?> json) {
    bool flag(String key, bool fallback) {
      final value = json[key];
      if (value is bool) {
        return value;
      }
      return value == null ? fallback : value.toString() == 'true';
    }

    int number(String key, int fallback) {
      final value = json[key];
      if (value is num) {
        return value.toInt();
      }
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    return IdentifiedStockSettings(
      enableSerializedInventory: flag('enable_serialized_inventory', false),
      enableBatchTracking: flag('enable_batch_tracking', false),
      captureLaterAllowed: flag('serialized_capture_later_allowed', false),
      requireCustomerForAsset: flag(
        'serialized_require_customer_for_asset',
        true,
      ),
      preventSellingExpiredBatches: flag(
        'prevent_selling_expired_batches',
        true,
      ),
      batchAutoPickStrategy: BatchPickStrategy.fromWire(
        json['batch_auto_pick_strategy'],
      ),
      defaultExpiryWarningDays: number('default_expiry_warning_days', 30),
      consignmentAutoSmsOnSale: flag('consignment_auto_sms_on_sale', true),
      consignmentDefaultLiabilityPolicy:
          json['consignment_default_liability_policy']?.toString() ??
          ConsignmentLiability.ownerRisk,
      consignmentClauseOwnerRisk:
          json['consignment_clause_owner_risk']?.toString() ?? '',
      consignmentClauseShopLiableExceptForceMajeure:
          json['consignment_clause_shop_liable_except_fm']?.toString() ?? '',
      consignmentClauseShopLiable:
          json['consignment_clause_shop_liable']?.toString() ?? '',
      consignmentRequireDeclaredValue: flag(
        'consignment_require_declared_value',
        true,
      ),
      consignmentUnclaimedPayoutReminderDays: number(
        'consignment_unclaimed_payout_reminder_days',
        30,
      ),
    );
  }

  /// IMEIs, serials, VINs: one article at a time.
  final bool enableSerializedInventory;

  /// Lots and expiry dates.
  final bool enableBatchTracking;

  /// Whether a delivery may be received before every article in it has been
  /// scanned. The articles wait on the missing-identifier list and cannot be
  /// sold until somebody names them.
  final bool captureLaterAllowed;

  /// Whether an identified article sold to a named customer is registered as
  /// that customer's device, so it arrives for repair already knowing its own
  /// history.
  final bool requireCustomerForAsset;

  /// The shop-wide floor under each product's own "do not sell expired" — a
  /// product may be stricter than the shop, never laxer.
  final bool preventSellingExpiredBatches;
  final BatchPickStrategy batchAutoPickStrategy;
  final int defaultExpiryWarningDays;

  final bool consignmentAutoSmsOnSale;

  /// One of the [ConsignmentLiability] values.
  final String consignmentDefaultLiabilityPolicy;

  /// The three clauses as the shop prints them on the consignment voucher.
  final String consignmentClauseOwnerRisk;
  final String consignmentClauseShopLiableExceptForceMajeure;
  final String consignmentClauseShopLiable;
  final bool consignmentRequireDeclaredValue;

  /// Days after which an uncollected payout starts reminding. 0 turns the
  /// reminder off.
  final int consignmentUnclaimedPayoutReminderDays;

  /// Whether any identified stock is on at all.
  bool get isAnyEnabled => enableSerializedInventory || enableBatchTracking;

  /// The clause the shop prints for [policy], one of [ConsignmentLiability].
  String clauseFor(String policy) => switch (policy) {
    ConsignmentLiability.shopLiableExceptForceMajeure =>
      consignmentClauseShopLiableExceptForceMajeure,
    ConsignmentLiability.shopLiable => consignmentClauseShopLiable,
    _ => consignmentClauseOwnerRisk,
  };

  IdentifiedStockSettings copyWith({
    bool? enableSerializedInventory,
    bool? enableBatchTracking,
    bool? captureLaterAllowed,
    bool? requireCustomerForAsset,
    bool? preventSellingExpiredBatches,
    BatchPickStrategy? batchAutoPickStrategy,
    int? defaultExpiryWarningDays,
    bool? consignmentAutoSmsOnSale,
    String? consignmentDefaultLiabilityPolicy,
    String? consignmentClauseOwnerRisk,
    String? consignmentClauseShopLiableExceptForceMajeure,
    String? consignmentClauseShopLiable,
    bool? consignmentRequireDeclaredValue,
    int? consignmentUnclaimedPayoutReminderDays,
  }) {
    return IdentifiedStockSettings(
      enableSerializedInventory:
          enableSerializedInventory ?? this.enableSerializedInventory,
      enableBatchTracking: enableBatchTracking ?? this.enableBatchTracking,
      captureLaterAllowed: captureLaterAllowed ?? this.captureLaterAllowed,
      requireCustomerForAsset:
          requireCustomerForAsset ?? this.requireCustomerForAsset,
      preventSellingExpiredBatches:
          preventSellingExpiredBatches ?? this.preventSellingExpiredBatches,
      batchAutoPickStrategy:
          batchAutoPickStrategy ?? this.batchAutoPickStrategy,
      defaultExpiryWarningDays:
          defaultExpiryWarningDays ?? this.defaultExpiryWarningDays,
      consignmentAutoSmsOnSale:
          consignmentAutoSmsOnSale ?? this.consignmentAutoSmsOnSale,
      consignmentDefaultLiabilityPolicy:
          consignmentDefaultLiabilityPolicy ??
          this.consignmentDefaultLiabilityPolicy,
      consignmentClauseOwnerRisk:
          consignmentClauseOwnerRisk ?? this.consignmentClauseOwnerRisk,
      consignmentClauseShopLiableExceptForceMajeure:
          consignmentClauseShopLiableExceptForceMajeure ??
          this.consignmentClauseShopLiableExceptForceMajeure,
      consignmentClauseShopLiable:
          consignmentClauseShopLiable ?? this.consignmentClauseShopLiable,
      consignmentRequireDeclaredValue:
          consignmentRequireDeclaredValue ??
          this.consignmentRequireDeclaredValue,
      consignmentUnclaimedPayoutReminderDays:
          consignmentUnclaimedPayoutReminderDays ??
          this.consignmentUnclaimedPayoutReminderDays,
    );
  }

  /// Only these keys: the page that saves it sends a partial update, so the
  /// rest of the shop's settings are never named, and never reset.
  Map<String, Object?> toJson() {
    return {
      'enable_serialized_inventory': enableSerializedInventory,
      'enable_batch_tracking': enableBatchTracking,
      'serialized_capture_later_allowed': captureLaterAllowed,
      'serialized_require_customer_for_asset': requireCustomerForAsset,
      'prevent_selling_expired_batches': preventSellingExpiredBatches,
      'batch_auto_pick_strategy': batchAutoPickStrategy.wire,
      'default_expiry_warning_days': defaultExpiryWarningDays,
      'consignment_auto_sms_on_sale': consignmentAutoSmsOnSale,
      'consignment_default_liability_policy': consignmentDefaultLiabilityPolicy,
      'consignment_clause_owner_risk': consignmentClauseOwnerRisk,
      'consignment_clause_shop_liable_except_fm':
          consignmentClauseShopLiableExceptForceMajeure,
      'consignment_clause_shop_liable': consignmentClauseShopLiable,
      'consignment_require_declared_value': consignmentRequireDeclaredValue,
      'consignment_unclaimed_payout_reminder_days':
          consignmentUnclaimedPayoutReminderDays,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is IdentifiedStockSettings &&
        other.enableSerializedInventory == enableSerializedInventory &&
        other.enableBatchTracking == enableBatchTracking &&
        other.captureLaterAllowed == captureLaterAllowed &&
        other.requireCustomerForAsset == requireCustomerForAsset &&
        other.preventSellingExpiredBatches == preventSellingExpiredBatches &&
        other.batchAutoPickStrategy == batchAutoPickStrategy &&
        other.defaultExpiryWarningDays == defaultExpiryWarningDays &&
        other.consignmentAutoSmsOnSale == consignmentAutoSmsOnSale &&
        other.consignmentDefaultLiabilityPolicy ==
            consignmentDefaultLiabilityPolicy &&
        other.consignmentClauseOwnerRisk == consignmentClauseOwnerRisk &&
        other.consignmentClauseShopLiableExceptForceMajeure ==
            consignmentClauseShopLiableExceptForceMajeure &&
        other.consignmentClauseShopLiable == consignmentClauseShopLiable &&
        other.consignmentRequireDeclaredValue ==
            consignmentRequireDeclaredValue &&
        other.consignmentUnclaimedPayoutReminderDays ==
            consignmentUnclaimedPayoutReminderDays;
  }

  @override
  int get hashCode => Object.hash(
    enableSerializedInventory,
    enableBatchTracking,
    captureLaterAllowed,
    requireCustomerForAsset,
    preventSellingExpiredBatches,
    batchAutoPickStrategy,
    defaultExpiryWarningDays,
    consignmentAutoSmsOnSale,
    consignmentDefaultLiabilityPolicy,
    consignmentClauseOwnerRisk,
    consignmentClauseShopLiableExceptForceMajeure,
    consignmentClauseShopLiable,
    consignmentRequireDeclaredValue,
    consignmentUnclaimedPayoutReminderDays,
  );
}
