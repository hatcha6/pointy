import '../../../data/models/product.dart';
import '../../../data/models/product_tracking.dart';
import '../../../data/models/tracking_mode.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';

/// The fields a run of new products can carry from one product to the next.
///
/// Codes are not among them — a barcode or SKU belongs to one product only —
/// and neither are a picture or a quantity on hand, which is counted, never
/// copied.
enum ProductCarryField {
  name,
  price,
  category,
  unit,

  /// How the product's stock is identified: the old expiry switch, or the
  /// whole tracking choice — mode, kind of device, warranty, lot policy —
  /// where the shop tracks identified stock. A phone shop entering its models
  /// one after another pins it once.
  tracksExpiry,
  openingCost;

  /// What carries over until the owner says otherwise: the classification a
  /// whole shelf shares. Name and price start unpinned on purpose — a carried
  /// price is exactly the value people accept without looking.
  static const pinnedByDefault = {category, unit};
}

/// The previous product's values, kept for whatever the next one carries.
class ProductCarryOverValues {
  const ProductCarryOverValues({
    required this.name,
    required this.price,
    required this.pricingCurrency,
    required this.categories,
    required this.unit,
    required this.tracksExpiry,
    required this.openingCost,
    ProductTracking? tracking,
  }) : tracking =
           tracking ??
           (tracksExpiry
               ? const ProductTracking(mode: TrackingMode.batch)
               : const ProductTracking());

  final String name;
  final String price;

  /// Travels with [price]: a price typed in dollars is not the same number in
  /// dinars, so the two carry over together or not at all.
  final String pricingCurrency;
  final List<AsyncSelectionOption<int>> categories;
  final String unit;
  final bool tracksExpiry;
  final String openingCost;

  /// The full tracking choice. Derived from [tracksExpiry] when not given, so
  /// the two cannot disagree.
  final ProductTracking tracking;

  /// Whether this field carried anything worth marking as the previous
  /// product's — not an empty field, nor the value every new product starts
  /// with anyway.
  bool hasValue(ProductCarryField field) {
    return switch (field) {
      ProductCarryField.name => name.isNotEmpty,
      ProductCarryField.price => price.isNotEmpty,
      ProductCarryField.category => categories.isNotEmpty,
      ProductCarryField.unit => unit != 'piece',
      ProductCarryField.tracksExpiry => tracking.mode.isTracked,
      ProductCarryField.openingCost => openingCost.isNotEmpty,
    };
  }
}

/// A run of products entered one after another without closing the panel:
/// the last one created, which fields go on to the next, and which still show
/// a value carried from the previous one.
///
/// It starts with the first «إنشاء وإضافة آخر» — before that there is no
/// previous product, so nothing to carry and no pins to show — or, for a
/// «منتج مشابه», with the product being copied ([startFrom]).
class ProductEntryRun {
  final Set<ProductCarryField> _pinned = {...ProductCarryField.pinnedByDefault};
  final Set<ProductCarryField> _kept = {};
  ProductCarryOverValues? _previous;
  var _createdCount = 0;
  Product? _lastCreated;
  var _lastCreatedImageFailed = false;

  bool get hasStarted => _previous != null;
  ProductCarryOverValues? get previous => _previous;
  int get createdCount => _createdCount;
  Product? get lastCreated => _lastCreated;
  bool get lastCreatedImageFailed => _lastCreatedImageFailed;

  bool isPinned(ProductCarryField field) => _pinned.contains(field);
  bool isKept(ProductCarryField field) => _kept.contains(field);

  /// The form shows a copy of an existing product and nothing has been
  /// created from it yet, so "the previous product" is that one.
  bool get copiesProduct => _previous != null && _createdCount == 0;

  /// Starts from an existing product — «منتج مشابه» — whose values the form
  /// opens with. Every one of them is marked as copied, the way a carried
  /// value is, until it is edited.
  void startFrom(ProductCarryOverValues source) {
    _previous = source;
    _kept
      ..clear()
      ..addAll(ProductCarryField.values.where(source.hasValue));
  }

  /// Records [product], created from [values], and settles what the next
  /// product starts with: every pinned field that had a value is carried and
  /// marked as the previous product's.
  void recordCreated(
    Product product,
    ProductCarryOverValues values, {
    required bool imageFailed,
  }) {
    _previous = values;
    _createdCount += 1;
    _lastCreated = product;
    _lastCreatedImageFailed = imageFailed;
    _kept
      ..clear()
      ..addAll(_pinned.where(values.hasValue));
  }

  /// Pins or unpins [field] and says whether it is pinned now.
  ///
  /// Unpinning leaves a carried value marked: it still came from the previous
  /// product, it simply stops going on to the next one.
  bool togglePin(ProductCarryField field) {
    if (_pinned.remove(field)) {
      return false;
    }
    _pinned.add(field);
    return true;
  }

  /// The field now shows the previous product's value again.
  void markKept(ProductCarryField field) {
    if (_previous?.hasValue(field) ?? false) {
      _kept.add(field);
    }
  }

  /// The field was edited, so what it shows is this product's own. True when
  /// that changed anything.
  bool unkeep(ProductCarryField field) => _kept.remove(field);

  /// Whether [name] is still the previous product's name — almost always a
  /// carried name nobody edited, which would leave two products sharing it.
  bool repeatsPreviousName(String name) {
    final previous = _previous;
    if (previous == null) {
      return false;
    }
    final normalized = _normalize(name);
    return normalized.isNotEmpty && normalized == _normalize(previous.name);
  }

  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');
}
