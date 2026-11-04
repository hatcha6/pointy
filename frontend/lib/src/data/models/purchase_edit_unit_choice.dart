import '../services/api_session.dart';

/// One serial line a received order cannot be shortened on until the owner
/// says which of its articles never arrived.
///
/// Editing a received order down from five handsets to three takes two off the
/// shelf — and each handset has its own number, so the server will not guess
/// which two. It answers `purchase_edit_units_required` with the handsets still
/// on the shelf; the owner ticks the right ones and the save is sent again with
/// them as `removed_units`.
class PurchaseEditUnitChoice {
  const PurchaseEditUnitChoice({
    required this.lineId,
    required this.productName,
    required this.removeCount,
    required this.candidates,
  });

  factory PurchaseEditUnitChoice.fromJson(Map<String, Object?> json) {
    final candidates = json['candidates'];
    return PurchaseEditUnitChoice(
      lineId: _asInt(json['line']),
      productName: json['product_name']?.toString() ?? '',
      removeCount: _asInt(json['remove_count']),
      candidates: candidates is List<Object?>
          ? candidates
                .whereType<Map<String, Object?>>()
                .map(PurchaseEditUnitCandidate.fromJson)
                .where((candidate) => candidate.id > 0)
                .toList(growable: false)
          : const [],
    );
  }

  final int lineId;
  final String productName;
  final int removeCount;
  final List<PurchaseEditUnitCandidate> candidates;
}

/// A handset still on the shelf that the owner may say never arrived.
class PurchaseEditUnitCandidate {
  const PurchaseEditUnitCandidate({required this.id, required this.code});

  factory PurchaseEditUnitCandidate.fromJson(Map<String, Object?> json) {
    return PurchaseEditUnitCandidate(
      id: _asInt(json['id']),
      code: json['code']?.toString() ?? '',
    );
  }

  final int id;
  final String code;
}

/// The choices a refused save asks for, or an empty list for any other error.
List<PurchaseEditUnitChoice> purchaseEditUnitChoicesFromException(
  Object error,
) {
  if (error is! PosApiException || error.statusCode != 400) {
    return const [];
  }
  final decoded = error.decodedBody;
  if (decoded is! Map<String, Object?> ||
      decoded['code']?.toString() != 'purchase_edit_units_required') {
    return const [];
  }
  final lines = decoded['lines'];
  if (lines is! List<Object?>) {
    return const [];
  }
  return lines
      .whereType<Map<String, Object?>>()
      .map(PurchaseEditUnitChoice.fromJson)
      .where((choice) => choice.removeCount > 0)
      .toList(growable: false);
}

// DRF renders every leaf of a validation error as a string.
int _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  _ => int.tryParse(value?.toString() ?? '') ?? 0,
};
