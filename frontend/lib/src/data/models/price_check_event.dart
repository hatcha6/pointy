/// Outcome of a single barcode scan recorded by a price checker.
enum PriceCheckResult { found, notFound, error, unknown }

/// Audit record for a barcode a price checker scanned, as returned by
/// `GET /api/price-check-events/`. Prices arrive as pre-formatted decimal
/// strings from the backend, so they are kept as strings for display.
class PriceCheckEvent {
  const PriceCheckEvent({
    required this.id,
    required this.result,
    required this.resultRaw,
    required this.barcode,
    this.deviceId,
    this.deviceIdentifier = '',
    this.productName = '',
    this.originalPrice,
    this.finalPrice,
    this.discountTotal,
    this.currency = '',
    this.sourceAddress = '',
    this.latencyMs,
    this.createdAt,
  });

  final int id;
  final PriceCheckResult result;
  final String resultRaw;
  final String barcode;
  final int? deviceId;
  final String deviceIdentifier;
  final String productName;
  final String? originalPrice;
  final String? finalPrice;
  final String? discountTotal;
  final String currency;
  final String sourceAddress;
  final int? latencyMs;
  final DateTime? createdAt;

  bool get wasFound => result == PriceCheckResult.found;

  factory PriceCheckEvent.fromJson(Map<String, Object?> json) {
    final resultRaw = json['result']?.toString() ?? '';
    return PriceCheckEvent(
      id: _intFromJson(json['id']),
      result: _resultFromJson(resultRaw),
      resultRaw: resultRaw,
      barcode: json['barcode']?.toString() ?? '',
      deviceId: _nullableIntFromJson(json['device']),
      deviceIdentifier: json['device_identifier']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      originalPrice: _nullableStringFromJson(json['original_price']),
      finalPrice: _nullableStringFromJson(json['final_price']),
      discountTotal: _nullableStringFromJson(json['discount_total']),
      currency: json['currency']?.toString() ?? '',
      sourceAddress: json['source_address']?.toString() ?? '',
      latencyMs: _nullableIntFromJson(json['latency_ms']),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

List<PriceCheckEvent> priceCheckEventsFromResponse(Object? decoded) {
  final items = decoded is Map<String, Object?> && decoded['results'] is List
      ? decoded['results'] as List<Object?>
      : decoded is List<Object?>
      ? decoded
      : const <Object?>[];

  return items
      .whereType<Map<String, Object?>>()
      .map(PriceCheckEvent.fromJson)
      .toList(growable: false);
}

PriceCheckResult _resultFromJson(String value) {
  return switch (value) {
    'found' => PriceCheckResult.found,
    'not_found' => PriceCheckResult.notFound,
    'error' => PriceCheckResult.error,
    _ => PriceCheckResult.unknown,
  };
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
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

String? _nullableStringFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString();
  return text.isEmpty ? null : text;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
