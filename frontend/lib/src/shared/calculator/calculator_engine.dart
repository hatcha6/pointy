import 'package:flutter/foundation.dart';

import 'calculator_number.dart';

/// The calculator's grammar and arithmetic, kept free of any UI.
///
/// The percent rules match Apple's Calculate engine (the one behind macOS
/// Calculator and Spotlight), verified case by case against the real engine:
///
/// - `a + b%` adds b percent OF a: 200 + 20% = 240, 200 − 20% = 160. "a" is
///   everything summed so far, so 200 + 20% + 10% = 264.
/// - That only applies when the right-hand side IS a percentage: 100 + 10% × 2
///   is 100.2 (10% × 2 = 0.2), and so are the plain-number forms 200 + −20%
///   (= 199.8) and 200 + 20%% (= 200.002). A bracketed one still counts:
///   200 + (10 + 10)% = 240.
/// - `a × b%` and `a ÷ b%` just use b/100: 40 and 1,000 for 200 and 20%.
/// - A percentage with nothing before it is b/100: 20% = 0.2, 20% + 200 =
///   200.2.
/// - `%` followed by a number is the remainder (5 % 3 = 2), floored like
///   Apple's `mod` (−7 % 3 = 2). Apple's string parser reads `2×5%3` as
///   2 × 5% × 3 while its own keypad reads `5%5` as 0; this follows the
///   keypad, consistently.
///
/// Deliberate differences: an unclosed bracket is closed for you, and
/// division by zero is an error rather than NaN/∞ (Apple shows "Undefined").

/// One element of what the user has entered.
@immutable
sealed class CalculatorToken {
  const CalculatorToken();
}

/// A number being typed: [digits] as entered ("1250", "12.", "" while a
/// pending minus waits for its first digit).
final class CalculatorNumberToken extends CalculatorToken {
  const CalculatorNumberToken(this.digits, {this.negative = false});

  final String digits;
  final bool negative;

  bool get isPending => digits.isEmpty;
  bool get hasDecimalPoint => digits.contains('.');

  CalculatorNumber? get value {
    final parsed = CalculatorNumber.tryParse(digits);
    if (parsed == null) {
      return null;
    }
    return negative ? -parsed : parsed;
  }

  CalculatorNumberToken copyWith({String? digits, bool? negative}) =>
      CalculatorNumberToken(
        digits ?? this.digits,
        negative: negative ?? this.negative,
      );

  @override
  bool operator ==(Object other) =>
      other is CalculatorNumberToken &&
      other.digits == digits &&
      other.negative == negative;

  @override
  int get hashCode => Object.hash(digits, negative);
}

/// An exact earlier result carried into a new calculation, so 1 ÷ 3 = then
/// × 3 = is exactly 1, not 0.9999999999.
final class CalculatorValueToken extends CalculatorToken {
  const CalculatorValueToken(this.value);

  final CalculatorNumber value;

  @override
  bool operator ==(Object other) =>
      other is CalculatorValueToken && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

enum CalculatorOperator {
  add('+'),
  subtract('−'),
  multiply('×'),
  divide('÷');

  const CalculatorOperator(this.symbol);

  final String symbol;
}

final class CalculatorOperatorToken extends CalculatorToken {
  const CalculatorOperatorToken(this.operator);

  final CalculatorOperator operator;

  @override
  bool operator ==(Object other) =>
      other is CalculatorOperatorToken && other.operator == operator;

  @override
  int get hashCode => operator.hashCode;
}

/// `%`: a percentage after its number, or the remainder between two.
final class CalculatorPercentToken extends CalculatorToken {
  const CalculatorPercentToken();

  @override
  bool operator ==(Object other) => other is CalculatorPercentToken;

  @override
  int get hashCode => 37;
}

final class CalculatorOpenParenToken extends CalculatorToken {
  const CalculatorOpenParenToken();

  @override
  bool operator ==(Object other) => other is CalculatorOpenParenToken;

  @override
  int get hashCode => 41;
}

final class CalculatorCloseParenToken extends CalculatorToken {
  const CalculatorCloseParenToken();

  @override
  bool operator ==(Object other) => other is CalculatorCloseParenToken;

  @override
  int get hashCode => 43;
}

/// Whether [token] can end an operand — what may stand before a binary
/// operator, `%`, or a closing bracket.
bool endsOperand(CalculatorToken? token) => switch (token) {
  CalculatorNumberToken(:final isPending) => !isPending,
  CalculatorValueToken() ||
  CalculatorCloseParenToken() ||
  CalculatorPercentToken() => true,
  _ => false,
};

/// Whether [token] can begin an operand.
bool startsOperand(CalculatorToken? token) =>
    token is CalculatorNumberToken ||
    token is CalculatorValueToken ||
    token is CalculatorOpenParenToken;

@immutable
sealed class CalculatorEvaluation {
  const CalculatorEvaluation();
}

final class CalculatorSuccess extends CalculatorEvaluation {
  const CalculatorSuccess(this.value);

  final CalculatorNumber value;
}

/// Nothing to compute yet: empty, or ending in an operator.
final class CalculatorIncomplete extends CalculatorEvaluation {
  const CalculatorIncomplete();
}

/// Division (or remainder) by zero — Apple's "Undefined".
final class CalculatorUndefined extends CalculatorEvaluation {
  const CalculatorUndefined();
}

/// Beyond 10^100: not a number anyone at a till means.
final class CalculatorOverflow extends CalculatorEvaluation {
  const CalculatorOverflow();
}

/// Tokens that do not form an expression (only reachable by pasting).
final class CalculatorInvalid extends CalculatorEvaluation {
  const CalculatorInvalid();
}

/// Evaluates [tokens]. Never throws.
CalculatorEvaluation evaluateCalculatorTokens(List<CalculatorToken> tokens) {
  if (tokens.isEmpty) {
    return const CalculatorIncomplete();
  }
  try {
    final parser = _Parser(tokens);
    final value = parser.parse().evaluate();
    if (value.reaches(100)) {
      return const CalculatorOverflow();
    }
    return CalculatorSuccess(value.bounded());
  } on _Incomplete {
    return const CalculatorIncomplete();
  } on _Invalid {
    return const CalculatorInvalid();
  } on CalculatorDivisionByZero {
    return const CalculatorUndefined();
  }
}

/// The operation `=` repeats when pressed again: the last top-level binary
/// operator and everything after it (Apple: 1 + 2 × 3 = 7, then = gives
/// 7 × 3 = 21; 200 + 20% = 240, then = gives 240 + 20% = 288). Null when
/// there is none, e.g. a bare number.
List<CalculatorToken>? repeatableTail(List<CalculatorToken> tokens) {
  var depth = 0;
  int? start;
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final previous = i == 0 ? null : tokens[i - 1];
    final next = i + 1 < tokens.length ? tokens[i + 1] : null;
    switch (token) {
      case CalculatorOpenParenToken():
        depth++;
      case CalculatorCloseParenToken():
        depth--;
      case CalculatorOperatorToken() when depth == 0 && endsOperand(previous):
        start = i;
      case CalculatorPercentToken()
          when depth == 0 && endsOperand(previous) && startsOperand(next):
        start = i;
      default:
        break;
    }
  }
  if (start == null) {
    return null;
  }
  return List.unmodifiable(tokens.sublist(start));
}

class _Incomplete implements Exception {
  const _Incomplete();
}

class _Invalid implements Exception {
  const _Invalid();
}

class _Parser {
  _Parser(this._tokens);

  final List<CalculatorToken> _tokens;
  int _position = 0;

  CalculatorToken? get _peek =>
      _position < _tokens.length ? _tokens[_position] : null;

  CalculatorToken? _peekAt(int offset) {
    final index = _position + offset;
    return index < _tokens.length ? _tokens[index] : null;
  }

  _Node parse() {
    final node = _additive();
    if (_peek != null) {
      throw const _Invalid();
    }
    return node;
  }

  _Node _additive() {
    var left = _multiplicative();
    while (true) {
      final token = _peek;
      if (token is! CalculatorOperatorToken ||
          (token.operator != CalculatorOperator.add &&
              token.operator != CalculatorOperator.subtract)) {
        return left;
      }
      _position++;
      left = _Additive(
        left,
        _multiplicative(),
        subtract: token.operator == CalculatorOperator.subtract,
      );
    }
  }

  _Node _multiplicative() {
    var left = _unary();
    while (true) {
      final token = _peek;
      if (token is CalculatorOperatorToken &&
          (token.operator == CalculatorOperator.multiply ||
              token.operator == CalculatorOperator.divide)) {
        _position++;
        left = _Binary(token.operator, left, _unary());
      } else if (token is CalculatorPercentToken && startsOperand(_peekAt(1))) {
        _position++;
        left = _Remainder(left, _unary());
      } else if (startsOperand(token)) {
        // 2(3), (1+1)(2), 5%(2): juxtaposition multiplies.
        left = _Binary(CalculatorOperator.multiply, left, _unary());
      } else {
        return left;
      }
    }
  }

  _Node _unary() {
    final token = _peek;
    if (token is CalculatorOperatorToken) {
      if (token.operator == CalculatorOperator.subtract) {
        _position++;
        return _Negate(_unary());
      }
      if (token.operator == CalculatorOperator.add) {
        _position++;
        return _unary();
      }
    }
    return _postfix();
  }

  _Node _postfix() {
    var node = _primary();
    while (_peek is CalculatorPercentToken && !startsOperand(_peekAt(1))) {
      _position++;
      node = _Percent(node);
    }
    return node;
  }

  _Node _primary() {
    final token = _peek;
    switch (token) {
      case null:
        throw const _Incomplete();
      case CalculatorNumberToken():
        final value = token.value;
        if (value == null) {
          throw token.isPending ? const _Incomplete() : const _Invalid();
        }
        _position++;
        return _Literal(value);
      case CalculatorValueToken():
        _position++;
        return _Literal(token.value);
      case CalculatorOpenParenToken():
        _position++;
        final inner = _additive();
        if (_peek is CalculatorCloseParenToken) {
          _position++;
        } else if (_peek != null) {
          throw const _Invalid();
        }
        // Otherwise the bracket was left open at the end: close it.
        return _Group(inner);
      case CalculatorOperatorToken() ||
          CalculatorPercentToken() ||
          CalculatorCloseParenToken():
        throw const _Invalid();
    }
  }
}

sealed class _Node {
  const _Node();

  CalculatorNumber evaluate();
}

final class _Literal extends _Node {
  const _Literal(this.value);

  final CalculatorNumber value;

  @override
  CalculatorNumber evaluate() => value;
}

final class _Group extends _Node {
  const _Group(this.inner);

  final _Node inner;

  @override
  CalculatorNumber evaluate() => inner.evaluate();
}

final class _Negate extends _Node {
  const _Negate(this.operand);

  final _Node operand;

  @override
  CalculatorNumber evaluate() => -operand.evaluate();
}

final class _Percent extends _Node {
  const _Percent(this.operand);

  final _Node operand;

  @override
  CalculatorNumber evaluate() => operand.evaluate() / CalculatorNumber.hundred;
}

final class _Binary extends _Node {
  const _Binary(this.operator, this.left, this.right);

  final CalculatorOperator operator;
  final _Node left;
  final _Node right;

  @override
  CalculatorNumber evaluate() {
    final a = left.evaluate();
    final b = right.evaluate();
    return switch (operator) {
      CalculatorOperator.add => a + b,
      CalculatorOperator.subtract => a - b,
      CalculatorOperator.multiply => a * b,
      CalculatorOperator.divide => a / b,
    };
  }
}

final class _Remainder extends _Node {
  const _Remainder(this.left, this.right);

  final _Node left;
  final _Node right;

  @override
  CalculatorNumber evaluate() => left.evaluate().remainder(right.evaluate());
}

/// `a ± b`, where a percentage b means "b percent of a".
final class _Additive extends _Node {
  const _Additive(this.left, this.right, {required this.subtract});

  final _Node left;
  final _Node right;
  final bool subtract;

  @override
  CalculatorNumber evaluate() {
    final a = left.evaluate();
    final percent = _relativePercent(right);
    final b = percent == null
        ? right.evaluate()
        : a * percent.operand.evaluate() / CalculatorNumber.hundred;
    return subtract ? a - b : a + b;
  }

  /// [node] (brackets aside) as a percentage of a plain operand — not a
  /// percentage of a percentage, which Apple treats as a plain number.
  static _Percent? _relativePercent(_Node node) {
    final unwrapped = _unwrap(node);
    if (unwrapped is _Percent && _unwrap(unwrapped.operand) is! _Percent) {
      return unwrapped;
    }
    return null;
  }

  static _Node _unwrap(_Node node) {
    var current = node;
    while (current is _Group) {
      current = current.inner;
    }
    return current;
  }
}
