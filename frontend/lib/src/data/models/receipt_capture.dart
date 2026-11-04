/// What a receiver wrote down while the goods were in front of them.
///
/// Identity is born at the receipt, but it may be *typed* earlier: a buyer
/// entering an order off the supplier's invoice already knows the expiry dates
/// and often the serials, so an order line carries the same rows as its plan
/// (`planned_units` / `planned_batches`) and the receipt starts from them.
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
    this.attributes = const {},
    this.warrantyOverrideExpiresOn,
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

  /// The condition checklist filled at intake (§6.2): battery health, grade,
  /// what came in the box. Coerced by the server against the article's kind.
  final Map<String, Object?> attributes;

  /// The article's own warranty end date, when it arrives with one that is
  /// not ours to compute — a car under its maker's warranty (§17.3).
  final DateTime? warrantyOverrideExpiresOn;

  /// Reads the rows the API echoes back (an order line's plan) and the ones
  /// this class writes to local storage — the same shape.
  factory ReceiptUnitCapture.fromJson(Map<String, Object?> json) {
    final attributes = json['attributes'];
    return ReceiptUnitCapture(
      code: json['code']?.toString() ?? '',
      secondaryCode: json['secondary_code']?.toString() ?? '',
      identifierKind: json['identifier_kind']?.toString() ?? '',
      unitCost: _doubleOrNull(json['unit_cost']),
      listPrice: _doubleOrNull(json['list_price']),
      notes: json['notes']?.toString() ?? '',
      attributes: attributes is Map
          ? Map<String, Object?>.from(attributes)
          : const {},
      warrantyOverrideExpiresOn: _dateOrNull(
        json['warranty_override_expires_on'],
      ),
    );
  }

  bool get hasDetails =>
      attributes.isNotEmpty || warrantyOverrideExpiresOn != null;

  bool get isIdentified => code.trim().isNotEmpty;

  ReceiptUnitCapture copyWith({
    String? code,
    String? secondaryCode,
    String? identifierKind,
    Object? unitCost = _noChange,
    Object? listPrice = _noChange,
    String? notes,
    Map<String, Object?>? attributes,
    Object? warrantyOverrideExpiresOn = _noChange,
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
      attributes: attributes ?? this.attributes,
      warrantyOverrideExpiresOn: identical(warrantyOverrideExpiresOn, _noChange)
          ? this.warrantyOverrideExpiresOn
          : warrantyOverrideExpiresOn as DateTime?,
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
      if (attributes.isNotEmpty) 'attributes': attributes,
      if (warrantyOverrideExpiresOn case final date?)
        'warranty_override_expires_on':
            '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}',
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

  factory ReceiptBatchCapture.fromJson(Map<String, Object?> json) {
    return ReceiptBatchCapture(
      code: json['code']?.toString() ?? '',
      quantity: _doubleOrNull(json['quantity']) ?? 0,
      expiryDate: _dateOrNull(json['expiry_date']),
      manufacturedOn: _dateOrNull(json['manufactured_on']),
      barcode: json['barcode']?.toString() ?? '',
    );
  }

  final String code;
  final double quantity;
  final DateTime? expiryDate;
  final DateTime? manufacturedOn;
  final String barcode;

  /// Nothing worth sending: no number, no quantity and no date. A lot that
  /// carries only an expiry is NOT empty — it is the whole point for a shop
  /// that tracks expiry and has never been told its lot numbers.
  bool get isEmpty =>
      code.trim().isEmpty &&
      quantity <= 0 &&
      expiryDate == null &&
      manufacturedOn == null;

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

  /// An order line's plan, or a stored draft line's capture.
  factory ReceiptLineCapture.fromJson(Object? units, Object? batches) {
    List<Map<String, Object?>> rows(Object? value) => value is List
        ? value
              .whereType<Map>()
              .map(Map<String, Object?>.from)
              .toList(growable: false)
        : const [];
    return ReceiptLineCapture(
      units: rows(units).map(ReceiptUnitCapture.fromJson).toList(),
      batches: rows(batches).map(ReceiptBatchCapture.fromJson).toList(),
    );
  }

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

/// The first of [batches] to expire, or null when none carries a date — what
/// a line that also asks for one expiry takes from its lots, so nobody types
/// the same date twice.
DateTime? earliestLotExpiry(Iterable<ReceiptBatchCapture> batches) {
  DateTime? earliest;
  for (final batch in batches) {
    final expiry = batch.expiryDate;
    if (expiry != null && (earliest == null || expiry.isBefore(earliest))) {
      earliest = expiry;
    }
  }
  return earliest;
}

double? _doubleOrNull(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => double.tryParse(text),
  _ => null,
};

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : DateTime.tryParse(text);
}

String _dateOnly(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

const Object _noChange = Object();
