import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/order/line_quantity_keyboard.dart';

KeyDownEvent _down(
  LogicalKeyboardKey logical, {
  PhysicalKeyboardKey physical = PhysicalKeyboardKey.keyA,
  String? character,
}) => KeyDownEvent(
  physicalKey: physical,
  logicalKey: logical,
  character: character,
  timeStamp: Duration.zero,
);

/// The digits a selected line hears, whatever keyboard layout the till uses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a QWERTY digit row and the numpad are digits', () {
    expect(
      quantityDigitFor(
        _down(
          LogicalKeyboardKey.digit7,
          physical: PhysicalKeyboardKey.digit7,
          character: '7',
        ),
      ),
      '7',
    );
    expect(quantityDigitFor(_down(LogicalKeyboardKey.numpad3)), '3');
  });

  test('an Arabic layout types Arabic-Indic digits, which are digits', () {
    final arabicFour = LogicalKeyboardKey(0x0664);
    expect(
      quantityDigitFor(
        _down(arabicFour, physical: PhysicalKeyboardKey.digit4, character: '٤'),
      ),
      '4',
    );
  });

  test('AZERTY puts symbols on the unshifted digit row', () {
    // «é» is what the 2 key types on a French layout.
    final eAcute = LogicalKeyboardKey(0x00e9);
    expect(
      quantityDigitFor(
        _down(eAcute, physical: PhysicalKeyboardKey.digit2, character: 'é'),
      ),
      '2',
    );
  });

  test('a letter is not a digit', () {
    expect(
      quantityDigitFor(_down(LogicalKeyboardKey.keyQ, character: 'q')),
      isNull,
    );
  });

  test('plus and minus, with or without the numpad', () {
    expect(isIncrementKey(_down(LogicalKeyboardKey.numpadAdd)), isTrue);
    expect(
      isIncrementKey(_down(LogicalKeyboardKey.equal, character: '=')),
      isTrue,
    );
    expect(
      isDecrementKey(_down(LogicalKeyboardKey.minus, character: '-')),
      isTrue,
    );
    expect(
      isQuantityDecimalKey(_down(LogicalKeyboardKey.period, character: '.')),
      isTrue,
    );
  });
}
