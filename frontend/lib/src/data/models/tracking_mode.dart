/// How closely a product's stock is identified.
///
/// [quantity] is what every product is until somebody says otherwise, and the
/// whole of this feature is gated on the other three: a shop that sells
/// Coca-Cola must not be able to tell that serialization and batch tracking
/// shipped. Read it off the product, never off a shop-wide setting — the same
/// pharmacy sells serialised imports and anonymous local stock out of one
/// catalog, which is what its shelves actually look like.
enum TrackingMode {
  /// A number in a bin. Today's behaviour, and the default.
  quantity('quantity'),

  /// Identified cohorts: a lot code, an expiry, a recall exposure.
  batch('batch'),

  /// Identified articles: an IMEI, a VIN, a serial. Quantity is always one.
  serial('serial'),

  /// An article *inside* a cohort — a serialised medicine pack. Not a third
  /// code path: it is [serial] with the lot required instead of optional.
  serialBatch('serial_batch');

  const TrackingMode(this.wire);

  /// The value the backend stores and sends.
  final String wire;

  static TrackingMode fromWire(Object? value) {
    final text = value?.toString() ?? '';
    for (final mode in TrackingMode.values) {
      if (mode.wire == text) {
        return mode;
      }
    }
    return TrackingMode.quantity;
  }

  /// Does this product's stock carry identity at all?
  bool get isTracked => this != TrackingMode.quantity;

  /// Is every article identified one at a time? True for [serial] and
  /// [serialBatch] — which is why no caller should ever write that pair out by
  /// hand and get one of the two wrong.
  bool get tracksUnits =>
      this == TrackingMode.serial || this == TrackingMode.serialBatch;

  /// Does this product's stock belong to identified cohorts?
  bool get tracksLots =>
      this == TrackingMode.batch || this == TrackingMode.serialBatch;

  /// Must every new article name the lot it was born in?
  bool get requiresLot => this == TrackingMode.serialBatch;
}
