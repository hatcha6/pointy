/// Reading what a cashier typed into the till's lookup box: a name, a code,
/// one article's identifier, or somebody's phone number.
library;

final RegExp _arabicLetter = RegExp('[ء-يٱ-ۓ]');
final RegExp _digit = RegExp('[0-9٠-٩۰-۹]');

/// Libyan mobile numbers as people write them: 09X…, 9X…, +218 9X…,
/// 00218 9X…, with spaces, dashes or dots anywhere, in either digit set.
final RegExp _libyanMobile = RegExp(r'^(?:\+?218|00218|0)?9[1-5][0-9]{7}$');
final RegExp _phoneSeparators = RegExp(r'[\s\-.()]');

/// What a phone number in telemetry is replaced with.
const String redactedPhoneTerm = '[phone]';

String _asciiDigits(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(0x30 + rune - 0x06F0);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Whether [value] is a Libyan mobile number — somebody's personal data, which
/// must not travel in search or scan telemetry.
bool looksLikePhoneNumber(String value) {
  final compact = _asciiDigits(value.trim()).replaceAll(_phoneSeparators, '');
  return _libyanMobile.hasMatch(compact);
}

/// Whether [value] reads as a product NAME rather than a code: it has Arabic
/// letters and either a space or no digits. A scanner never types a space,
/// and a Latin code it typed on the Arabic layout still carries its digits.
bool looksLikeTypedName(String value) {
  final text = value.trim();
  if (!_arabicLetter.hasMatch(text)) {
    return false;
  }
  return text.contains(' ') || !_digit.hasMatch(text);
}

/// Separators people and labels put inside an identifier, which the server's
/// `normalize_identifier` drops: spaces, dashes, dots, slashes, bidi marks.
final RegExp _identifierSeparators = RegExp(
  '[\\s\\-_./\\\\\u200e\u200f\u00a0]',
);
final RegExp _latinCode = RegExp(r'^[A-Z0-9]+$');
final RegExp _asciiDigit = RegExp('[0-9]');

/// [value] in the form the server matches identifiers in: digits folded to
/// ASCII, separators dropped, upper case. `351234-567890116` and
/// `٣٥١٢٣٤٥٦٧٨٩٠١١٦` are both `351234567890116`.
String normalizeUnitIdentifier(String value) => _asciiDigits(
  value.trim(),
).replaceAll(_identifierSeparators, '').toUpperCase();

/// Whether [value] reads as ONE article's identifier — an IMEI (15 digits), a
/// VIN (17 characters), a serial — rather than a product name or a word.
///
/// The other side of [looksLikeTypedName]: no space between words (a scanner
/// never types one, and a name has them), at least six Latin letters and
/// digits once the separators a label prints are dropped, and at least one
/// digit, so «charger» or «SAMSUNG» stay a product search. A product barcode
/// passes too; what that costs is one indexed probe that finds nothing.
bool looksLikeUnitIdentifier(String value) {
  final text = value.trim();
  if (text.isEmpty || text.contains(' ') || looksLikeTypedName(text)) {
    return false;
  }
  final code = normalizeUnitIdentifier(text);
  return code.length >= 6 &&
      code.length <= 64 &&
      _latinCode.hasMatch(code) &&
      _asciiDigit.hasMatch(code);
}
