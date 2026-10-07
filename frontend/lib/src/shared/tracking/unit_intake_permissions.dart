import '../../core/authorization.dart';

/// What a person taking articles in may set beyond their identity.
///
/// Each is the unit page's own permission — repricing a handset
/// (`inventory.reprice_stockunit`) and promising a customer its own warranty
/// date (`inventory.change_stockunit_warranty`) — and the server asks it again
/// when the receipt posts, so a field hidden here is also refused there.
class UnitIntakePermissions {
  const UnitIntakePermissions({
    this.canSetPrice = false,
    this.canSetWarranty = false,
  });

  factory UnitIntakePermissions.of(AuthorizationCapabilities? capabilities) {
    if (capabilities == null) return none;
    return UnitIntakePermissions(
      canSetPrice: capabilities.canRepriceStockUnit,
      canSetWarranty: capabilities.canChangeStockUnitWarranty,
    );
  }

  static const none = UnitIntakePermissions();

  final bool canSetPrice;
  final bool canSetWarranty;
}
