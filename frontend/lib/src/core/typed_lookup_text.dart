/// Reading what a cashier typed into the till's lookup box: a name, a code,
/// or somebody's phone number.
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
