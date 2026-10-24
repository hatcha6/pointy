/// Libyan mobile numbers as people type and read them.
abstract final class LibyanPhone {
  /// The national number ("9XXXXXXXX") of what was typed, or null. Accepts
  /// 09…, 9…, 2189…, +218 9…, 00218 9…, spaces, dashes and Arabic digits.
  static String? national(String raw) {
    final digits = StringBuffer();
    for (final rune in raw.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        digits.writeCharCode(rune);
      } else if (rune >= 0x0660 && rune <= 0x0669) {
        digits.writeCharCode(0x30 + rune - 0x0660);
      }
    }
    var number = digits.toString();
    if (number.startsWith('00218')) {
      number = number.substring(5);
    } else if (number.startsWith('218')) {
      number = number.substring(3);
    } else if (number.startsWith('0')) {
      number = number.substring(1);
    }
    return number.length == 9 && number.startsWith('9') ? number : null;
  }

  /// "091 234 5678" for a national number.
  static String display(String national) {
    final local = '0$national';
    if (local.length != 10) {
      return local;
    }
    return '${local.substring(0, 3)} ${local.substring(3, 6)} ${local.substring(6)}';
  }
}
