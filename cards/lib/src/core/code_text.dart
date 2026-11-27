/// A delivered code that carries its PIN on the same line, the way
/// fazercards writes an Apple card: "XPRCMDHC6W6G6PCJ / PIN: XPRCMDHC6W6G6PCJ".
/// Copied whole, that line is not a code any store takes, and the redeem
/// link (which checks the code's shape) is not offered for it.
final _labelledPin = RegExp(
  r'^(.*?)\s*(?:[/|,;]\s*)?\bpin(?:\s*code)?\s*[:：#=]\s*(\S.*?)\s*$',
  caseSensitive: false,
);

/// A code written after its own label ("Code: XXXX").
final _labelledCode = RegExp(
  r'^(?:code|key|card(?:\s*number)?)\s*[:：#=]\s*',
  caseSensitive: false,
);

/// [line] as the code alone, and the PIN written after it (empty when there
/// is none, or when it only repeats the code). The relay reads codes this
/// way too; this also mends the ones a phone saved before it did.
({String code, String pin}) splitLabelledCode(String line) {
  var code = line.trim();
  var pin = '';
  final match = _labelledPin.firstMatch(code);
  if (match != null && match.group(1)!.trim().isNotEmpty) {
    code = match.group(1)!;
    pin = match.group(2)!.trim();
  }
  code = code.replaceFirst(_labelledCode, '').trim();
  code = code.replaceFirst(RegExp(r'[\s/|,;-]+$'), '');
  if (pin.toUpperCase() == code.toUpperCase()) {
    pin = '';
  }
  return (code: code, pin: pin);
}
