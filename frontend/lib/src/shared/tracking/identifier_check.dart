/// What looks wrong with an identifier, checked where it is scanned.
///
/// The client half of `backend/apps/inventory/identity.py`'s IMEI rules, so a
/// mistyped IMEI is caught while the box is still open rather than at a
/// warranty claim two years later. Only a warning: a guard that walls off a
/// legitimate oddity gets switched off, and then it catches nothing.
enum IdentifierProblem { imeiNotNumeric, imeiLength, imeiChecksum }

/// The wire value of an IMEI line's `identifier_kind`.
const String imeiIdentifierKind = 'imei';

/// Null when [code] looks right for [kind], or [kind] has no rule here.
IdentifierProblem? checkIdentifier(String code, {required String kind}) {
  if (kind != imeiIdentifierKind) {
    return null;
  }
  final digits = code.replaceAll(RegExp(r'[\s\-._/]'), '');
  if (digits.isEmpty) {
    return null;
  }
  if (!RegExp(r'^[0-9]+$').hasMatch(digits)) {
    return IdentifierProblem.imeiNotNumeric;
  }
  // 14 = IMEI without its check digit, 15 = IMEI, 16 = IMEISV.
  if (digits.length < 14 || digits.length > 16) {
    return IdentifierProblem.imeiLength;
  }
  // Only the 15-digit form carries the Luhn digit; an IMEISV replaces it with
  // a software version, so checking one would fail every time.
  if (digits.length == 15 && !luhnValid(digits)) {
    return IdentifierProblem.imeiChecksum;
  }
  return null;
}

/// The Luhn check over a string of digits, last digit included.
bool luhnValid(String digits) {
  var sum = 0;
  var doubleIt = false;
  for (var index = digits.length - 1; index >= 0; index -= 1) {
    var digit = digits.codeUnitAt(index) - 0x30;
    if (doubleIt) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    doubleIt = !doubleIt;
  }
  return sum % 10 == 0;
}
