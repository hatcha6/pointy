import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A barcode scanner, as the till hears one: a keyboard that types a number
/// fast — a key every 15 ms — and ends with Enter.
///
/// Hand [clock] to the `BarcodeScanListener` under test: key events are real
/// in a widget test but wall-clock time is not, so the burst timing must be
/// driven explicitly.
class ScanBurst {
  DateTime now = DateTime(2026, 1, 1, 12);

  DateTime clock() => now;

  static const _digitKeys = {
    '0': LogicalKeyboardKey.digit0,
    '1': LogicalKeyboardKey.digit1,
    '2': LogicalKeyboardKey.digit2,
    '3': LogicalKeyboardKey.digit3,
    '4': LogicalKeyboardKey.digit4,
    '5': LogicalKeyboardKey.digit5,
    '6': LogicalKeyboardKey.digit6,
    '7': LogicalKeyboardKey.digit7,
    '8': LogicalKeyboardKey.digit8,
    '9': LogicalKeyboardKey.digit9,
  };

  /// Types [digits] into the focused field the way the platform would — each
  /// key reaches the hardware keyboard (where the listener hears it), then
  /// its character reaches the field — and finishes with Enter. Returns
  /// whether that Enter was swallowed by a handler (a completed scan) rather
  /// than left for the field.
  Future<bool> typeAndEnter(WidgetTester tester, String digits) async {
    var typed = '';
    for (final character in digits.split('')) {
      now = now.add(const Duration(milliseconds: 15));
      await tester.sendKeyEvent(_digitKeys[character]!);
      typed += character;
      tester.testTextInput.enterText(typed);
      await tester.pump();
    }
    now = now.add(const Duration(milliseconds: 15));
    final consumed = await simulateKeyDownEvent(LogicalKeyboardKey.enter);
    await simulateKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    return consumed;
  }
}
