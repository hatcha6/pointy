/// What a receiver wrote down while the goods were in front of them.
///
/// Identifiers are captured **where the goods physically are** — at the
/// receiving bay, not on the purchase order — so these travel with the receipt
/// and nowhere else. A purchase line carries a count; it never carries a serial.
library;

/// One identified article on a delivery.
class ReceiptUnitCapture {
  const ReceiptUnitCapture({
    this.code = '',
    this.secondaryCode = '',
    this.identifierKind = '',
    this.unitCost,
    this.listPrice,
    this.notes = '',
  });

  /// Blank means the shop is taking the goods now and owes the number later —
  /// which is only allowed when the shop has opted into that, and produces a
  /// placeholder the till refuses to sell.
  final String code;

  /// The second number an article legitimately answers to: a dual-SIM handset's
  /// IMEI2, an engine number, a MAC address, a bicycle's frame number.
  final String secondaryCode;
  final String identifierKind;

  /// What *this* article cost, when the delivery's cost is not spread evenly.
  /// Used goods have individual costs and a purchase line has one total; the
  /// capture sheet keeps the residual visible and the backend refuses a set
  /// that does not add up.
  final double? unitCost;
  final double? listPrice;
  final String notes;

  bool get isIdentified => code.trim().isNotEmpty;

  ReceiptUnitCapture copyWith({
    String? code,
    String? secondaryCode,
    String? identifierKind,
    Object? unitCost = _noChange,
    Object? listPrice = _noChange,
    String? notes,
  }) {
    return ReceiptUnitCapture(
      code: code ?? this.code,
      secondaryCode: secondaryCode ?? this.secondaryCode,
      identifierKind: identifierKind ?? this.identifierKind,
      unitCost: identical(unitCost, _noChange)
          ? this.unitCost
          : unitCost as double?,
      listPrice: identical(listPrice, _noChange)
          ? this.listPrice
          : listPrice as double?,
      notes: notes ?? this.notes,
    );
  }

  Map<String, Object?> toJson() {
    return {
      if (code.trim().isNotEmpty) 'code': code.trim(),
      if (secondaryCode.trim().isNotEmpty)
        'secondary_code': secondaryCode.trim(),
      if (identifierKind.isNotEmpty) 'identifier_kind': identifierKind,
      if (unitCost != null) 'unit_cost': unitCost!.toStringAsFixed(6),
      if (listPrice != null) 'list_price': listPrice!.toStringAsFixed(2),
      if (notes.trim().isNotEmpty) 'notes': notes.trim(),
    };
  }
}

/// One production lot on a delivery, with how much of it arrived.
///
/// Deliveries routinely bundle several lots under one order line, so a line may
/// carry more than one of these — and their quantities must sum to what was
/// accepted, which is the residual the capture sheet counts down.
class ReceiptBatchCapture {
  const ReceiptBatchCapture({
    this.code = '',
    this.quantity = 0,
    this.expiryDate,
    this.manufacturedOn,
    this.barcode = '',
  });

  final String code;
  final double quantity;
  final DateTime? expiryDate;
  final DateTime? manufacturedOn;
  final String barcode;

  bool get isEmpty => code.trim().isEmpty && quantity <= 0;

  ReceiptBatchCapture copyWith({
    String? code,
    double? quantity,
    Object? expiryDate = _noChange,
    Object? manufacturedOn = _noChange,
    String? barcode,
  }) {
    return ReceiptBatchCapture(
      code: code ?? this.code,
      quantity: quantity ?? this.quantity,
      expiryDate: identical(expiryDate, _noChange)
          ? this.expiryDate
          : expiryDate as DateTime?,
      manufacturedOn: identical(manufacturedOn, _noChange)
          ? this.manufacturedOn
          : manufacturedOn as DateTime?,
      barcode: barcode ?? this.barcode,
    );
  }

  Map<String, Object?> toJson() {
    return {
      if (code.trim().isNotEmpty) 'code': code.trim(),
      if (quantity > 0) 'quantity': quantity.toStringAsFixed(3),
      if (expiryDate != null) 'expiry_date': _dateOnly(expiryDate!),
      if (manufacturedOn != null) 'manufactured_on': _dateOnly(manufacturedOn!),
      if (barcode.trim().isNotEmpty) 'barcode': barcode.trim(),
    };
  }
}

/// Everything captured for one receipt line: its articles, its lots, or both.
///
/// Both, for `serial_batch`: one lot header and a scan loop beneath it, because
/// a serialised pharmaceutical pack is a unit inside a cohort and a receiver
/// should type the lot once rather than once per pack.
class ReceiptLineCapture {
  const ReceiptLineCapture({this.units = const [], this.batches = const []});

  final List<ReceiptUnitCapture> units;
  final List<ReceiptBatchCapture> batches;

  bool get isEmpty => units.isEmpty && batches.isEmpty;

  int get identifiedCount => units.where((unit) => unit.isIdentified).length;

  double get capturedBatchQuantity =>
      batches.fold<double>(0, (sum, batch) => sum + batch.quantity);

  /// The per-unit costs a receiver has typed, or null when they left them alone.
  ///
  /// All or nothing: a partial split is ambiguous — it could mean "these three
  /// cost this and the rest share what is left", which is not something the
  /// backend can check — so the sheet either sends every cost or none.
  double? get capturedUnitCost {
    final declared = units.where((unit) => unit.unitCost != null).toList();
    if (declared.isEmpty || declared.length != units.length) {
      return null;
    }
    return declared.fold<double>(0, (sum, unit) => sum + unit.unitCost!);
  }

  Map<String, Object?> toJson() {
    return {
      if (units.isNotEmpty)
        'units': units.map((unit) => unit.toJson()).toList(growable: false),
      if (batches.isNotEmpty)
        'batches': batches
            .where((batch) => !batch.isEmpty)
            .map((batch) => batch.toJson())
            .toList(growable: false),
    };
  }
}

String _dateOnly(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

const Object _noChange = Object();
