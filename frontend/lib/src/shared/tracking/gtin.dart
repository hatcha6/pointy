import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// Why a typed GTIN is not one. Mirrors `apps/catalog/gs1.normalize_gtin`, so
/// the form refuses the same typos the server would — before the save.
enum GtinProblem { notDigits, length, checkDigit }

const _gtinLengths = {8, 12, 13, 14};
final _separators = RegExp(r'[\s\-]');
final _digits = RegExp(r'^\d+$');

/// The GS1 mod-10 check digit for [body] (the number without it): weighted
/// 3, 1, 3, … from the right, which is why left-padding never changes it.
int gtinCheckDigit(String body) {
  var total = 0;
  for (var position = 0; position < body.length; position++) {
    final digit = body.codeUnitAt(body.length - 1 - position) - 48;
    total += digit * (position.isEven ? 3 : 1);
  }
  return (10 - total % 10) % 10;
}

/// What is wrong with [raw], or null when it is blank or a valid GTIN.
GtinProblem? gtinProblem(String raw) {
  final text = raw.replaceAll(_separators, '');
  if (text.isEmpty) {
    return null;
  }
  if (!_digits.hasMatch(text)) {
    return GtinProblem.notDigits;
  }
  if (!_gtinLengths.contains(text.length)) {
    return GtinProblem.length;
  }
  final check = text.codeUnitAt(text.length - 1) - 48;
  if (check != gtinCheckDigit(text.substring(0, text.length - 1))) {
    return GtinProblem.checkDigit;
  }
  return null;
}

/// [raw] as the GTIN-14 the server stores, '' when blank, null when invalid.
String? normalizeGtin(String raw) {
  final text = raw.replaceAll(_separators, '');
  if (text.isEmpty) {
    return '';
  }
  if (gtinProblem(text) != null) {
    return null;
  }
  return text.padLeft(14, '0');
}

/// The GTIN inside a scanned GS1 element string — what a DataMatrix sends —
/// or null when [raw] is not one. Lets a scanner pointed at the GTIN field
/// fill it from the box rather than from the printed digits.
String? gtinFromGs1Scan(String raw) {
  var text = raw.trim();
  for (final prefix in const [']d2', ']C1', ']e0', ']Q3']) {
    if (text.startsWith(prefix)) {
      text = text.substring(prefix.length);
      break;
    }
  }
  if (text.length <= 16 || !text.startsWith('01')) {
    return null;
  }
  final candidate = text.substring(2, 16);
  return gtinProblem(candidate) == null ? candidate : null;
}

String gtinProblemMessage(AppLocalizations l10n, GtinProblem problem) {
  return switch (problem) {
    GtinProblem.notDigits => l10n.gtinErrorNotDigits,
    GtinProblem.length => l10n.gtinErrorLength,
    GtinProblem.checkDigit => l10n.gtinErrorCheckDigit,
  };
}
