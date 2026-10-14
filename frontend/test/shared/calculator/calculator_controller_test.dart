import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/calculator/calculator_controller.dart';
import 'package:pointy_frontend/src/shared/calculator/calculator_engine.dart';

/// Presses keys by their keypad symbols: digits, + − × ÷ % . ( ) = and
/// C (clear), ⌫ (backspace), ± (sign), Z ("00").
void press(CalculatorController c, String keys) {
  for (final key in keys.split('')) {
    switch (key) {
      case 'C':
        c.clear();
      case '⌫':
        c.backspace();
      case '±':
        c.toggleSign();
      case 'Z':
        c.inputDoubleZero();
      case '−':
        c.inputOperator(CalculatorOperator.subtract);
      default:
        expect(c.inputCharacter(key), isTrue, reason: 'key $key');
    }
  }
}

String shown(CalculatorController c) =>
    c.result?.format(minusSign: '-') ?? c.expressionText;

void main() {
  late CalculatorController c;
  setUp(() => c = CalculatorController());

  // Each sequence below was pressed on macOS Calculator (Oct 2026) and the
  // display read back; the expectations are what it showed.
  group('macOS Calculator keypad parity', () {
    test('200 + 20 % shows the expression, = gives 240, = again 288', () {
      press(c, '200+20%');
      expect(c.expressionText, '200+20%');
      expect(c.preview?.format(), '240');
      press(c, '=');
      expect(c.expressionText, '200+20%');
      expect(shown(c), '240');
      press(c, '=');
      expect(c.expressionText, '240+20%');
      expect(shown(c), '288');
    });

    test('2 + 3 = then a digit starts fresh', () {
      press(c, '2+3=7');
      expect(c.result, isNull);
      expect(c.expressionText, '7');
      press(c, '+1=');
      expect(c.expressionText, '7+1');
      expect(shown(c), '8');
    });

    test('an operator after = continues from the result', () {
      press(c, '7+1=×');
      expect(c.expressionText, '8×');
      press(c, '2=');
      expect(shown(c), '16');
    });

    test('9 ÷ 0 = is undefined, and the next key starts over', () {
      press(c, '9÷0=');
      expect(c.error, CalculatorErrorKind.undefined);
      expect(c.expressionText, '9÷0');
      press(c, '4');
      expect(c.error, isNull);
      expect(c.expressionText, '4');
    });

    test('a second operator replaces the first', () {
      press(c, '5+×');
      expect(c.expressionText, '5×');
    });

    test('± wraps the number being typed', () {
      press(c, '5×2±');
      expect(c.expressionText, '5×(−2)');
      press(c, '=');
      expect(shown(c), '-10');
    });

    test('= repeats only the last operation', () {
      press(c, '1+2×3=');
      expect(shown(c), '7');
      press(c, '=');
      expect(c.expressionText, '7×3');
      expect(shown(c), '21');

      press(c, 'C5×2+3==');
      expect(c.expressionText, '13+3');
      expect(shown(c), '16');
    });

    test('% followed by a number is the remainder', () {
      press(c, '5%5');
      expect(c.expressionText, '5%5');
      press(c, '=');
      expect(shown(c), '0');
    });

    test('% straight after an operator is ignored', () {
      press(c, '5×%');
      expect(c.expressionText, '5×');
    });
  });

  group('editing', () {
    test('an operator on an empty display works on 0', () {
      press(c, '+5=');
      expect(c.expressionText, '0+5');
      expect(shown(c), '5');
    });

    test('− after × starts a negative number instead of replacing', () {
      press(c, '5×−2=');
      expect(c.expressionText, '5×(−2)');
      expect(shown(c), '-10');
    });

    test('backspace removes characters, then tokens', () {
      press(c, '12+34⌫');
      expect(c.expressionText, '12+3');
      press(c, '⌫⌫');
      expect(c.expressionText, '12');
      press(c, '⌫⌫⌫');
      expect(c.isEmpty, isTrue);
    });

    test('backspace on a result clears', () {
      press(c, '2+2=⌫');
      expect(c.isEmpty, isTrue);
    });

    test('leading zeros collapse and the point gets a zero', () {
      press(c, '007');
      expect(c.expressionText, '7');
      press(c, 'C.5');
      expect(c.expressionText, '0.5');
      press(c, '..');
      expect(c.expressionText, '0.5');
    });

    test('00 key', () {
      press(c, '2ZZ');
      expect(c.expressionText, '20,000');
      press(c, 'C');
      press(c, 'Z');
      expect(c.expressionText, '0');
    });

    test('digit limits', () {
      press(c, '1' * 20);
      expect(c.expressionText.replaceAll(',', '').length, 15);
      press(c, 'C0.${'1' * 20}');
      expect(c.expressionText, '0.${'1' * 10}');
    });

    test('groups thousands while typing, keeping typed decimals', () {
      press(c, '1250.50');
      expect(c.expressionText, '1,250.50');
    });

    test('Arabic-Indic digits, ٫ and ٪', () {
      c.inputText('٢٠٠+٢٠٪');
      press(c, '=');
      expect(shown(c), '240');
      press(c, 'C');
      c.inputText('٢٠٠٫٥+١=');
      expect(shown(c), '201.5');
    });

    test('pasting skips grouping and unknown characters', () {
      c.inputText('1,234 + 1 =');
      expect(shown(c), '1,235');
    });

    test('an unclosed bracket is closed on =', () {
      press(c, '2×(3+4=');
      expect(shown(c), '14');
    });

    test('exact through a chain: 1 ÷ 3 = × 3 = is 1', () {
      press(c, '1÷3=×3=');
      expect(shown(c), '1');
    });

    test('incomplete = does nothing', () {
      press(c, '5+');
      expect(c.evaluate(), isFalse);
      expect(c.expressionText, '5+');
    });
  });

  group('values and history', () {
    test('records each = with the newest first', () {
      press(c, '2+2=3×3=');
      expect(c.history.map((e) => e.expression), ['3×3', '2+2']);
      expect(c.history.first.result.format(), '9');
    });

    test('history is capped', () {
      final small = CalculatorController(historyLimit: 3);
      for (var i = 1; i <= 5; i++) {
        press(small, '$i+0=');
      }
      expect(small.history.length, 3);
      expect(small.history.first.expression, '5+0');
    });

    test('a tape value becomes the operand after an operator', () {
      press(c, '2+2=');
      final four = c.history.first.result;
      press(c, 'C10+');
      c.useValue(four);
      press(c, '=');
      expect(shown(c), '14');
    });

    test('currentValue: result, else live answer, else typed number', () {
      press(c, '12');
      expect(c.currentValue?.toPlainString(), '12');
      press(c, '+3');
      expect(c.currentValue?.toPlainString(), '15');
      press(c, '=');
      expect(c.currentValue?.toPlainString(), '15');
      press(c, '÷0=');
      expect(c.currentValue, isNull);
    });

    test('a bare number shows no live answer', () {
      press(c, '200');
      expect(c.preview, isNull);
    });
  });
}
