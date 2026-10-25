import 'package:flutter/services.dart';

/// The networks a Libyan bank card belongs to, read from its first digits.
enum CardNetwork { visa, mastercard, local, unknown }

/// Checks and shapes for what the card form takes, before anything is sent:
/// a mistyped digit is caught here, not as a bank's refusal.
abstract final class CardNumber {
  /// Western digits only; Arabic-Indic digits typed on an Arabic keyboard
  /// count too.
  static String digits(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        buffer.writeCharCode(rune);
      } else if (rune >= 0x660 && rune <= 0x669) {
        buffer.writeCharCode(rune - 0x660 + 0x30);
      } else if (rune >= 0x6F0 && rune <= 0x6F9) {
        buffer.writeCharCode(rune - 0x6F0 + 0x30);
      }
    }
    return buffer.toString();
  }

  static CardNetwork networkOf(String number) {
    final digits = CardNumber.digits(number);
    if (digits.startsWith('4')) {
      return CardNetwork.visa;
    }
    final two = digits.length >= 2 ? int.parse(digits.substring(0, 2)) : -1;
    final four = digits.length >= 4 ? int.parse(digits.substring(0, 4)) : -1;
    if ((two >= 51 && two <= 55) || (four >= 2221 && four <= 2720)) {
      return CardNetwork.mastercard;
    }
    // Libya's own cards (NUMO and the banks' local cards) start with 6.
    if (digits.startsWith('6')) {
      return CardNetwork.local;
    }
    return CardNetwork.unknown;
  }

  /// A complete number: 16 to 19 digits (local cards run longer than 16)
  /// that pass the Luhn check every card number carries.
  static bool isValid(String number) {
    final digits = CardNumber.digits(number);
    if (digits.length < 16 || digits.length > 19) {
      return false;
    }
    var sum = 0;
    for (var i = 0; i < digits.length; i++) {
      var digit = digits.codeUnitAt(digits.length - 1 - i) - 0x30;
      if (i.isOdd) {
        digit *= 2;
        if (digit > 9) {
          digit -= 9;
        }
      }
      sum += digit;
    }
    return sum % 10 == 0;
  }

  /// MM/YY read into (month, two-digit year), or null when it is not a
  /// month to come within twenty years.
  static (int, int)? expiry(String text, {DateTime? now}) {
    final digits = CardNumber.digits(text);
    if (digits.length != 4) {
      return null;
    }
    final month = int.parse(digits.substring(0, 2));
    final year = int.parse(digits.substring(2));
    if (month < 1 || month > 12) {
      return null;
    }
    final today = now ?? DateTime.now();
    final full = 2000 + year;
    final ends = DateTime(full, month + 1);
    if (!ends.isAfter(today) || full > today.year + 20) {
      return null;
    }
    return (month, year);
  }
}

/// Groups the number in fours as it is typed: 6395 0438 3518 0860.
class CardNumberFormatter extends TextInputFormatter {
  const CardNumberFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = CardNumber.digits(newValue.text);
    final capped = digits.length > 19 ? digits.substring(0, 19) : digits;
    final buffer = StringBuffer();
    for (var i = 0; i < capped.length; i++) {
      if (i > 0 && i % 4 == 0) {
        buffer.write(' ');
      }
      buffer.write(capped[i]);
    }
    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// MM/YY, the slash put in after the month.
class ExpiryFormatter extends TextInputFormatter {
  const ExpiryFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = CardNumber.digits(newValue.text);
    if (digits.length > 4) {
      digits = digits.substring(0, 4);
    }
    // Deleting the slash deletes the month's last digit with it.
    final deleting = newValue.text.length < oldValue.text.length;
    final text = digits.length > 2 || (digits.length == 2 && !deleting)
        ? '${digits.substring(0, 2)}/${digits.substring(2)}'
        : digits;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
