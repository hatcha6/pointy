/// Price-computing scale barcodes (grocery deli/produce labels).
///
/// Digital scales print EAN-13 codes in the de-facto in-store format
/// `2P IIIII WWWWW C`: a `20`–`29` prefix, a 5-digit item code, the weight in
/// grams, and the EAN check digit. The item code identifies the product (the
/// product's catalog barcode is the 5-digit code, optionally without leading
/// zeros, or the full 7-digit prefix+code), and the embedded weight becomes
/// the sold quantity in kilograms.
class ScaleBarcode {
  const ScaleBarcode({
    required this.raw,
    required this.itemCode,
    required this.weightKg,
  });

  final String raw;
  final String itemCode;
  final double weightKg;

  /// Barcodes to try when matching the catalog, most specific first.
  List<String> get candidateBarcodes {
    final trimmedItemCode = itemCode.replaceFirst(RegExp(r'^0+'), '');
    final candidates = <String>[
      raw.substring(0, 7),
      itemCode,
      if (trimmedItemCode.isNotEmpty && trimmedItemCode != itemCode)
        trimmedItemCode,
    ];
    return candidates.toSet().toList(growable: false);
  }
}

/// Parses [raw] as a weight-embedded scale barcode, or returns null.
ScaleBarcode? parseScaleBarcode(String raw) {
  final code = raw.trim();
  if (code.length != 13 || !RegExp(r'^\d{13}$').hasMatch(code)) {
    return null;
  }
  if (!code.startsWith('2')) {
    return null;
  }
  if (!isValidEan13(code)) {
    return null;
  }
  final grams = int.tryParse(code.substring(7, 12));
  if (grams == null || grams <= 0) {
    return null;
  }
  return ScaleBarcode(
    raw: code,
    itemCode: code.substring(2, 7),
    weightKg: grams / 1000,
  );
}

bool isValidEan13(String code) {
  if (code.length != 13) {
    return false;
  }
  var sum = 0;
  for (var index = 0; index < 12; index++) {
    final digit = code.codeUnitAt(index) - 0x30;
    if (digit < 0 || digit > 9) {
      return false;
    }
    sum += digit * (index.isEven ? 1 : 3);
  }
  final check = (10 - (sum % 10)) % 10;
  return check == code.codeUnitAt(12) - 0x30;
}
