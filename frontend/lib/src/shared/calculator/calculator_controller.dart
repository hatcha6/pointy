import 'package:flutter/foundation.dart';

import 'calculator_engine.dart';
import 'calculator_number.dart';

/// What the display shows instead of a number.
enum CalculatorErrorKind { undefined, overflow }

/// One finished calculation in the tape.
@immutable
class CalculatorHistoryEntry {
  const CalculatorHistoryEntry({
    required this.expression,
    required this.result,
  });

  /// The expression as it was displayed, e.g. "200+20%".
  final String expression;
  final CalculatorNumber result;
}

/// The keypad's state machine, modelled on macOS Calculator (checked by
/// pressing the real keys):
///
/// - The display is an expression ("200+20%"), not a single register. `=`
///   moves it to the small line and shows the result.
/// - After `=`, a digit starts a fresh calculation; an operator, `%` or `±`
///   continues from the result (2 + 3 = 5, then × → "5×").
/// - Pressing `=` again repeats the last operation: 200 + 20% = 240, = 288.
/// - A second operator replaces the first (5 + × → "5×") — except `−` after
///   × or ÷, which starts a negative number (5 × −2), as typed.
/// - `±` wraps the number being typed: 5 × (−2).
/// - After an error ("Undefined") the next key starts over.
///
/// Inputs are plain methods so the keypad buttons and the keyboard share one
/// path, and so tests can drive it without widgets.
class CalculatorController extends ChangeNotifier {
  CalculatorController({this.historyLimit = 50});

  final int historyLimit;

  /// Longest number accepted: 15 whole digits (a trillion-dinar till is not a
  /// thing) and 10 decimals.
  static const int maxWholeDigits = 15;
  static const int maxFractionDigits = 10;

  /// Cap on the whole expression, so a held key cannot grow it forever.
  static const int maxTokens = 64;

  List<CalculatorToken> _tokens = const [];
  List<CalculatorToken> _evaluatedTokens = const [];
  List<CalculatorToken>? _repeatTail;
  CalculatorNumber? _result;
  CalculatorErrorKind? _error;
  final List<CalculatorHistoryEntry> _history = [];

  /// What is being typed.
  List<CalculatorToken> get tokens => List.unmodifiable(_tokens);

  /// The result of the last `=`, while it is on the display.
  CalculatorNumber? get result => _result;
  CalculatorErrorKind? get error => _error;

  /// Whether the display shows a finished calculation (result or error).
  bool get showsOutcome => _result != null || _error != null;

  bool get isEmpty => _tokens.isEmpty && !showsOutcome;

  /// The expression line: what is being typed, or the one just evaluated.
  String get expressionText =>
      formatCalculatorTokens(showsOutcome ? _evaluatedTokens : _tokens);

  /// The live answer while typing (Apple's inline evaluation), only once the
  /// expression actually computes something — "200" alone shows none.
  CalculatorNumber? get preview {
    if (showsOutcome || !_tokens.any((t) => t is! CalculatorNumberToken)) {
      return null;
    }
    final evaluation = evaluateCalculatorTokens(_tokens);
    return evaluation is CalculatorSuccess ? evaluation.value : null;
  }

  /// The number worth copying or inserting right now: the result, else the
  /// live answer, else the number being typed.
  CalculatorNumber? get currentValue {
    if (_error != null) {
      return null;
    }
    if (_result != null) {
      return _result;
    }
    final live = preview;
    if (live != null) {
      return live;
    }
    final evaluation = evaluateCalculatorTokens(_tokens);
    return evaluation is CalculatorSuccess ? evaluation.value : null;
  }

  /// The amount the currency converter works on: like [currentValue], but
  /// mid-expression it is the part already complete — "200+" converts 200,
  /// not nothing, so the converted line does not blink out on each operator.
  CalculatorNumber? get conversionInput {
    final value = currentValue;
    if (value != null || _error != null) {
      return value;
    }
    var tokens = _tokens;
    while (tokens.isNotEmpty && !endsOperand(tokens.last)) {
      tokens = tokens.sublist(0, tokens.length - 1);
    }
    final evaluation = evaluateCalculatorTokens(_withClosedBrackets(tokens));
    return evaluation is CalculatorSuccess ? evaluation.value : null;
  }

  List<CalculatorHistoryEntry> get history => List.unmodifiable(_history);

  CalculatorToken? get _last => _tokens.isEmpty ? null : _tokens.last;

  void inputDigit(int digit) {
    assert(digit >= 0 && digit <= 9);
    _startFreshIfOutcome();
    _appendDigits('$digit');
    notifyListeners();
  }

  /// The "00" key: two zeros, or one where a leading zero would be pointless.
  void inputDoubleZero() {
    _startFreshIfOutcome();
    _appendDigits('00');
    notifyListeners();
  }

  void inputDecimalPoint() {
    _startFreshIfOutcome();
    final last = _last;
    if (last is CalculatorNumberToken) {
      if (!last.hasDecimalPoint) {
        _replaceLast(
          last.copyWith(digits: '${last.isPending ? '0' : last.digits}.'),
        );
      }
    } else if (_canStartOperand) {
      _push(const CalculatorNumberToken('0.'));
    }
    notifyListeners();
  }

  void inputOperator(CalculatorOperator operator) {
    _continueFromOutcome();
    final last = _last;
    if (last == null) {
      // Like Apple, an operator on an empty display operates on 0.
      _push(const CalculatorNumberToken('0'));
      _push(CalculatorOperatorToken(operator));
    } else if (endsOperand(last)) {
      _push(CalculatorOperatorToken(operator));
    } else if (last is CalculatorOperatorToken) {
      final multiplicative =
          last.operator == CalculatorOperator.multiply ||
          last.operator == CalculatorOperator.divide;
      if (operator == CalculatorOperator.subtract && multiplicative) {
        _push(const CalculatorNumberToken('', negative: true));
      } else if (_tokens.length >= 2 &&
          endsOperand(_tokens[_tokens.length - 2])) {
        _replaceLast(CalculatorOperatorToken(operator));
      }
    } else if (last is CalculatorOpenParenToken &&
        operator == CalculatorOperator.subtract) {
      _push(const CalculatorNumberToken('', negative: true));
    } else if (last is CalculatorNumberToken && last.isPending) {
      // "5×(−" then another operator: drop the pending minus, swap the operator.
      _tokens = _tokens.sublist(0, _tokens.length - 1);
      if (_last is CalculatorOperatorToken &&
          operator != CalculatorOperator.subtract) {
        _replaceLast(CalculatorOperatorToken(operator));
      }
    }
    notifyListeners();
  }

  void inputPercent() {
    _continueFromOutcome();
    if (endsOperand(_last)) {
      _push(const CalculatorPercentToken());
    }
    notifyListeners();
  }

  /// `±`: flips the sign of the number being typed (or of the result), or
  /// starts a negative one after an operator.
  void toggleSign() {
    if (_result != null) {
      _result = -_result!;
      _evaluatedTokens = [CalculatorValueToken(_result!)];
      _repeatTail = null;
      notifyListeners();
      return;
    }
    _clearError();
    final last = _last;
    if (last is CalculatorNumberToken) {
      _replaceLast(last.copyWith(negative: !last.negative));
    } else if (last is CalculatorValueToken) {
      _replaceLast(CalculatorValueToken(-last.value));
    } else if (_canStartOperand && last is! CalculatorPercentToken) {
      _push(const CalculatorNumberToken('', negative: true));
    }
    notifyListeners();
  }

  void inputOpenParen() {
    _startFreshIfOutcome();
    if (_canStartOperand || endsOperand(_last)) {
      // After an operand this is implicit multiplication: 2(3) = 6.
      _push(const CalculatorOpenParenToken());
    }
    notifyListeners();
  }

  void inputCloseParen() {
    if (showsOutcome) {
      return;
    }
    final open = _tokens.whereType<CalculatorOpenParenToken>().length;
    final closed = _tokens.whereType<CalculatorCloseParenToken>().length;
    if (open > closed && endsOperand(_last)) {
      _push(const CalculatorCloseParenToken());
      notifyListeners();
    }
  }

  /// ⌫: removes the last character typed. On a result it clears, since a
  /// result is not something you typed.
  void backspace() {
    if (showsOutcome) {
      clear();
      return;
    }
    final last = _last;
    if (last == null) {
      return;
    }
    if (last is CalculatorNumberToken && !last.isPending) {
      final digits = last.digits.substring(0, last.digits.length - 1);
      if (digits.isEmpty && !last.negative) {
        _tokens = _tokens.sublist(0, _tokens.length - 1);
      } else {
        _replaceLast(last.copyWith(digits: digits));
      }
    } else {
      _tokens = _tokens.sublist(0, _tokens.length - 1);
    }
    notifyListeners();
  }

  /// C: clears the display. The tape stays.
  void clear() {
    _tokens = const [];
    _evaluatedTokens = const [];
    _repeatTail = null;
    _result = null;
    _error = null;
    notifyListeners();
  }

  /// `=`. Returns whether anything was computed.
  bool evaluate() {
    if (_error != null) {
      return false;
    }
    final List<CalculatorToken> expression;
    if (_result != null) {
      final tail = _repeatTail;
      if (tail == null) {
        return false;
      }
      expression = [CalculatorValueToken(_result!), ...tail];
    } else {
      expression = _withClosedBrackets(_tokens);
    }
    final evaluation = evaluateCalculatorTokens(expression);
    switch (evaluation) {
      case CalculatorIncomplete() || CalculatorInvalid():
        return false;
      case CalculatorUndefined():
        _showError(expression, CalculatorErrorKind.undefined);
      case CalculatorOverflow():
        _showError(expression, CalculatorErrorKind.overflow);
      case CalculatorSuccess(:final value):
        _evaluatedTokens = expression;
        _repeatTail = repeatableTail(expression) ?? _repeatTail;
        _result = value;
        _error = null;
        _tokens = const [];
        _record(expression, value);
    }
    notifyListeners();
    return true;
  }

  /// Puts [value] (a tape entry, say) where the next number would go: after
  /// an operator it becomes the operand, otherwise it replaces the display.
  void useValue(CalculatorNumber value) {
    if (showsOutcome || !_canStartOperand) {
      _reset();
    }
    _push(CalculatorValueToken(value));
    notifyListeners();
  }

  void clearHistory() {
    _history.clear();
    notifyListeners();
  }

  /// An opaque copy of the display, for [restore] — how the keyboard handler
  /// takes back digits a barcode scanner typed into the calculator.
  Object snapshot() => _Snapshot(
    tokens: _tokens,
    evaluatedTokens: _evaluatedTokens,
    repeatTail: _repeatTail,
    result: _result,
    error: _error,
  );

  void restore(Object snapshot) {
    if (snapshot is! _Snapshot) {
      return;
    }
    _tokens = snapshot.tokens;
    _evaluatedTokens = snapshot.evaluatedTokens;
    _repeatTail = snapshot.repeatTail;
    _result = snapshot.result;
    _error = snapshot.error;
    notifyListeners();
  }

  /// Types [text] — a pasted "200+20%", say — one character at a time
  /// through the same inputs as the keys. Unknown characters are skipped.
  void inputText(String text) {
    for (final rune in text.runes) {
      inputCharacter(String.fromCharCode(rune));
    }
  }

  /// One typed character. Returns whether the calculator understood it.
  /// Accepts Western, Arabic-Indic (٠–٩) and Persian (۰–۹) digits, `٫` as the
  /// decimal point and `٪` as percent, like Apple's engine.
  bool inputCharacter(String character) {
    final digit = calculatorDigitValue(character);
    if (digit != null) {
      inputDigit(digit);
      return true;
    }
    switch (character) {
      case '.' || '٫':
        inputDecimalPoint();
      case '+':
        inputOperator(CalculatorOperator.add);
      case '-' || '−' || '–':
        inputOperator(CalculatorOperator.subtract);
      case '*' || '×' || 'x' || 'X':
        inputOperator(CalculatorOperator.multiply);
      case '/' || '÷':
        inputOperator(CalculatorOperator.divide);
      case '%' || '٪':
        inputPercent();
      case '(':
        inputOpenParen();
      case ')':
        inputCloseParen();
      case '=':
        evaluate();
      default:
        // Grouping commas and spaces in a pasted number mean nothing.
        return character == ',' || character == ' ' || character == '٬';
    }
    return true;
  }

  bool get _canStartOperand {
    final last = _last;
    return last == null ||
        last is CalculatorOperatorToken ||
        last is CalculatorOpenParenToken ||
        // "5%" then a number: the remainder.
        last is CalculatorPercentToken;
  }

  void _appendDigits(String digits) {
    final last = _last;
    if (last is CalculatorNumberToken) {
      _replaceLast(last.copyWith(digits: _grow(last.digits, digits)));
      return;
    }
    if (last is CalculatorValueToken || last is CalculatorCloseParenToken) {
      // A number straight after a result or ")" multiplies, like 2(3).
      if (_tokens.length >= maxTokens) {
        return;
      }
      _push(const CalculatorOperatorToken(CalculatorOperator.multiply));
    }
    if (_canStartOperand) {
      _push(CalculatorNumberToken(_grow('', digits)));
    }
  }

  /// [current] with [added] typed after it, within the digit limits and
  /// without pointless leading zeros ("007" is "7").
  String _grow(String current, String added) {
    var text = current;
    for (final digit in added.split('')) {
      final point = text.indexOf('.');
      if (point < 0) {
        if (text == '0') {
          text = digit;
          continue;
        }
        if (text.length >= maxWholeDigits) {
          break;
        }
      } else if (text.length - point - 1 >= maxFractionDigits) {
        break;
      }
      text += digit;
    }
    return text;
  }

  void _push(CalculatorToken token) {
    if (_tokens.length >= maxTokens) {
      return;
    }
    _tokens = [..._tokens, token];
  }

  void _replaceLast(CalculatorToken token) {
    _tokens = [..._tokens.sublist(0, _tokens.length - 1), token];
  }

  /// Before a digit, `.`, `(` or a tape value: a finished calculation is put
  /// away and a new one begins.
  void _startFreshIfOutcome() {
    if (showsOutcome) {
      _reset();
    }
  }

  /// Before an operator, `%`: continue from the result; after an error,
  /// start over.
  void _continueFromOutcome() {
    final result = _result;
    if (result != null) {
      _reset();
      _tokens = [CalculatorValueToken(result)];
    } else if (_error != null) {
      _reset();
    }
  }

  void _clearError() {
    if (_error != null) {
      _reset();
    }
  }

  void _reset() {
    _tokens = const [];
    _evaluatedTokens = const [];
    _repeatTail = null;
    _result = null;
    _error = null;
  }

  void _showError(List<CalculatorToken> expression, CalculatorErrorKind kind) {
    _evaluatedTokens = expression;
    _repeatTail = null;
    _result = null;
    _error = kind;
    _tokens = const [];
  }

  void _record(List<CalculatorToken> expression, CalculatorNumber value) {
    _history.insert(
      0,
      CalculatorHistoryEntry(
        expression: formatCalculatorTokens(expression),
        result: value,
      ),
    );
    if (_history.length > historyLimit) {
      _history.removeRange(historyLimit, _history.length);
    }
  }

  static List<CalculatorToken> _withClosedBrackets(
    List<CalculatorToken> tokens,
  ) {
    final open = tokens.whereType<CalculatorOpenParenToken>().length;
    final closed = tokens.whereType<CalculatorCloseParenToken>().length;
    return [
      ...tokens,
      for (var i = closed; i < open; i++) const CalculatorCloseParenToken(),
    ];
  }
}

class _Snapshot {
  const _Snapshot({
    required this.tokens,
    required this.evaluatedTokens,
    required this.repeatTail,
    required this.result,
    required this.error,
  });

  final List<CalculatorToken> tokens;
  final List<CalculatorToken> evaluatedTokens;
  final List<CalculatorToken>? repeatTail;
  final CalculatorNumber? result;
  final CalculatorErrorKind? error;
}

/// 0–9 for a Western, Arabic-Indic or Persian digit; null otherwise.
int? calculatorDigitValue(String character) {
  if (character.length != 1) {
    return null;
  }
  final code = character.codeUnitAt(0);
  for (final zero in const [0x30, 0x0660, 0x06F0]) {
    if (code >= zero && code <= zero + 9) {
      return code - zero;
    }
  }
  return null;
}

/// The expression as the display shows it: "1,250+20%×(−3)". Always Western
/// digits and LTR order — the display isolates it inside the Arabic UI.
String formatCalculatorTokens(List<CalculatorToken> tokens) {
  final buffer = StringBuffer();
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final leading = i == 0 || tokens[i - 1] is CalculatorOpenParenToken;
    switch (token) {
      case CalculatorNumberToken(:final digits, :final negative):
        final text = _groupTyped(digits);
        if (!negative) {
          buffer.write(text);
        } else if (leading) {
          buffer.write('−$text');
        } else {
          // Apple's "5×(−2)": bracketed so it never reads as 5×−2 or 5−2.
          buffer.write(digits.isEmpty ? '(−' : '(−$text)');
        }
      case CalculatorValueToken(:final value):
        final text = value.format();
        buffer.write(value.isNegative && !leading ? '($text)' : text);
      case CalculatorOperatorToken(:final operator):
        buffer.write(operator.symbol);
      case CalculatorPercentToken():
        buffer.write('%');
      case CalculatorOpenParenToken():
        buffer.write('(');
      case CalculatorCloseParenToken():
        buffer.write(')');
    }
  }
  return buffer.toString();
}

/// Groups the whole part of a number as typed, keeping what follows the
/// point exactly as entered ("1250.50" → "1,250.50").
String _groupTyped(String digits) {
  final point = digits.indexOf('.');
  if (point < 0) {
    return groupDigits(digits);
  }
  final whole = digits.substring(0, point);
  return '${groupDigits(whole.isEmpty ? '0' : whole)}${digits.substring(point)}';
}
