import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/calculator/calculator_engine.dart';
import 'package:pointy_frontend/src/shared/calculator/calculator_number.dart';

/// Builds tokens straight from text, without the keypad's editing rules, so
/// these tests exercise the grammar alone.
List<CalculatorToken> tokensOf(String text) {
  final tokens = <CalculatorToken>[];
  final number = StringBuffer();
  void flush() {
    if (number.isNotEmpty) {
      tokens.add(CalculatorNumberToken(number.toString()));
      number.clear();
    }
  }

  for (final char in text.split('')) {
    if (RegExp(r'[0-9.]').hasMatch(char)) {
      number.write(char);
      continue;
    }
    flush();
    tokens.add(switch (char) {
      '+' => const CalculatorOperatorToken(CalculatorOperator.add),
      '-' => const CalculatorOperatorToken(CalculatorOperator.subtract),
      '*' => const CalculatorOperatorToken(CalculatorOperator.multiply),
      '/' => const CalculatorOperatorToken(CalculatorOperator.divide),
      '%' => const CalculatorPercentToken(),
      '(' => const CalculatorOpenParenToken(),
      ')' => const CalculatorCloseParenToken(),
      _ => throw ArgumentError(char),
    });
  }
  flush();
  return tokens;
}

String? displayed(String text) {
  final evaluation = evaluateCalculatorTokens(tokensOf(text));
  return switch (evaluation) {
    CalculatorSuccess(:final value) => value.format(minusSign: '-'),
    _ => null,
  };
}

void main() {
  group('matches Apple Calculate on', () {
    // Expected values recorded from /System/Library/PrivateFrameworks/
    // Calculate.framework (Calculate.evaluate) on macOS, Oct 2026.
    const cases = <String, String>{
      '200+20%': '240',
      '200-20%': '160',
      '200*20%': '40',
      '200/20%': '1,000',
      '20%': '0.2',
      '50%': '0.5',
      '20%*200': '40',
      '20%+200': '200.2',
      '200+20%+10%': '264',
      '200+20%-10%': '216',
      '100+10%*2': '100.2',
      '100*2+10%': '220',
      '100+2*10%': '100.2',
      '(200+20)%': '2.2',
      '200+(20%)': '240',
      '200+(10+10)%': '240',
      '10%%': '0.001',
      '200+20%%': '200.002',
      '-20%': '-0.2',
      '200+-20%': '199.8',
      '200--20%': '200.2',
      '0.1+0.2': '0.3',
      '10/3*3': '10',
      '1+2*3': '7',
      '2(3)': '6',
      '.5+.5': '1',
      '5.': '5',
      '007+1': '8',
      '3.5%': '0.035',
      '1234567.891': '1,234,567.891',
      '5%5': '0',
      '7%3': '1',
      '200+5%3': '202',
      '5%3%': '0.02',
    };
    for (final MapEntry(key: input, value: expected) in cases.entries) {
      test(input, () => expect(displayed(input), expected));
    }
  });

  group('errors and incomplete input', () {
    test('division by zero is undefined', () {
      expect(
        evaluateCalculatorTokens(tokensOf('1/0')),
        isA<CalculatorUndefined>(),
      );
      expect(
        evaluateCalculatorTokens(tokensOf('0/0')),
        isA<CalculatorUndefined>(),
      );
      expect(
        evaluateCalculatorTokens(tokensOf('5%0')),
        isA<CalculatorUndefined>(),
      );
    });

    test('a trailing operator is incomplete, not an error', () {
      expect(
        evaluateCalculatorTokens(tokensOf('5-')),
        isA<CalculatorIncomplete>(),
      );
      expect(
        evaluateCalculatorTokens(tokensOf('200+')),
        isA<CalculatorIncomplete>(),
      );
      expect(evaluateCalculatorTokens(const []), isA<CalculatorIncomplete>());
    });

    test('an open bracket at the end is closed for you', () {
      expect(displayed('2*(3+4'), '14');
    });

    test('a stray close bracket is invalid', () {
      expect(
        evaluateCalculatorTokens(tokensOf('2)')),
        isA<CalculatorInvalid>(),
      );
    });

    test('absurdly large is an overflow', () {
      final huge = '9' * 15;
      expect(
        evaluateCalculatorTokens(tokensOf(List.filled(8, huge).join('*'))),
        isA<CalculatorOverflow>(),
      );
    });
  });

  group('remainder is floored like Apple mod', () {
    CalculatorNumber n(String s) => CalculatorNumber.tryParse(s)!;
    test('-7 mod 3 = 2', () => expect(n('-7').remainder(n('3')), n('2')));
    test('7 mod -3 = -2', () => expect(n('7').remainder(n('-3')), n('-2')));
    test('7.5 mod 2 = 1.5', () => expect(n('7.5').remainder(n('2')), n('1.5')));
  });

  group('display formatting', () {
    String f(String text) => displayed(text)!;
    test('rounds half away from zero to 10 decimals', () {
      expect(f('2/3'), '0.6666666667');
      expect(f('1/3'), '0.3333333333');
      expect(f('100000/3'), '33,333.3333333333');
    });
    test('keeps 15 significant digits for large values', () {
      expect(f('99999999999999.5+0'), '99,999,999,999,999.5');
    });
    test('switches to scientific notation past 15 digits', () {
      expect(f('123456789*987654321'), '1.219326311×10¹⁷');
      expect(f('1000000*1000000000'), '1×10¹⁵');
      expect(f('0.000001*0.000001'), '1×10⁻¹²');
    });
    test('plain strings are field-safe', () {
      final value = CalculatorNumber.tryParse('-1234.5')!;
      expect(value.toPlainString(), '-1234.5');
      expect(value.format(), '−1,234.5');
    });
  });

  group('repeatable tail', () {
    String? tail(String text) {
      final found = repeatableTail(tokensOf(text));
      if (found == null) {
        return null;
      }
      return found
          .map(
            (t) => switch (t) {
              CalculatorNumberToken(:final digits) => digits,
              CalculatorOperatorToken(:final operator) => operator.symbol,
              CalculatorPercentToken() => '%',
              CalculatorOpenParenToken() => '(',
              CalculatorCloseParenToken() => ')',
              CalculatorValueToken(:final value) => value.toPlainString(),
            },
          )
          .join();
    }

    test('last top-level operator and its operand (Apple keypad)', () {
      expect(tail('200+20%'), '+20%');
      expect(tail('1+2*3'), '×3');
      expect(tail('5*2+3'), '+3');
      expect(tail('2*(3+4)'), '×(3+4)');
      expect(tail('5%3'), '%3');
    });

    test('a lone number repeats nothing', () {
      expect(tail('5'), isNull);
      expect(tail('20%'), isNull);
    });

    test('a unary minus is not the operation', () {
      expect(tail('-5'), isNull);
      expect(tail('2*-5'), '×\u22125');
    });
  });
}
