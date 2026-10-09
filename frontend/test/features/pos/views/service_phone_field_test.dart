import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_phone_field.dart';

/// What the number field makes of a number as it arrives: typed, or pasted
/// from a chat that wrapped it in direction marks.
void main() {
  const formatter = PhoneGroupFormatter();

  TextEditingValue paste(String text) => formatter.formatEditUpdate(
    TextEditingValue.empty,
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );

  test('groups typed digits in pairs from the left', () {
    expect(paste('70123456').text, '70 12 34 56');
  });

  test('keeps the plus of a number copied with direction marks around it', () {
    for (final raw in const [
      '\u{202A}+223 70 12 34 56\u{202C}',
      '\u{200E}+223 70 12 34 56',
      '\u{2066}+223 70 12 34 56\u{2069}',
      '(+223) 70 12 34 56',
      ' +223 70 12 34 56',
      '＋223 70 12 34 56',
    ]) {
      final text = paste(raw).text;
      expect(text, startsWith('+'), reason: raw);
      expect(
        text.replaceAll(RegExp(r'[^0-9]'), ''),
        '22370123456',
        reason: raw,
      );
    }
  });

  test('keeps a leading 00 as digits, for the view model to read', () {
    expect(
      paste('\u{202A}00223 70 12 34 56\u{202C}').text.replaceAll(' ', ''),
      '0022370123456',
    );
  });

  test('a plus in the middle of a number is not a plus', () {
    expect(paste('70+123456').text, isNot(contains('+')));
  });

  test('Arabic digits become digits', () {
    expect(paste('٧٠١٢٣٤٥٦').text, '70 12 34 56');
  });
}
