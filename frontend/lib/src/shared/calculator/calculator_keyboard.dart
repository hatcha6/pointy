import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'calculator_controller.dart';
import 'calculator_engine.dart';

/// The keys on the calculator's keypad — also what a keyboard press flashes.
enum CalculatorKey {
  clear,
  backspace,
  percent,
  divide,
  seven,
  eight,
  nine,
  multiply,
  four,
  five,
  six,
  subtract,
  one,
  two,
  three,
  add,
  doubleZero,
  zero,
  decimal,
  equals;

  static CalculatorKey digit(int value) => switch (value) {
    0 => zero,
    1 => one,
    2 => two,
    3 => three,
    4 => four,
    5 => five,
    6 => six,
    7 => seven,
    8 => eight,
    _ => nine,
  };

  int? get digitValue => switch (this) {
    zero => 0,
    one => 1,
    two => 2,
    three => 3,
    four => 4,
    five => 5,
    six => 6,
    seven => 7,
    eight => 8,
    nine => 9,
    _ => null,
  };

  void applyTo(CalculatorController controller) {
    final digit = digitValue;
    if (digit != null) {
      controller.inputDigit(digit);
      return;
    }
    switch (this) {
      case clear:
        controller.clear();
      case backspace:
        controller.backspace();
      case percent:
        controller.inputPercent();
      case divide:
        controller.inputOperator(CalculatorOperator.divide);
      case multiply:
        controller.inputOperator(CalculatorOperator.multiply);
      case subtract:
        controller.inputOperator(CalculatorOperator.subtract);
      case add:
        controller.inputOperator(CalculatorOperator.add);
      case doubleZero:
        controller.inputDoubleZero();
      case decimal:
        controller.inputDecimalPoint();
      case equals:
        controller.evaluate();
      default:
        break;
    }
  }
}

/// What the panel does besides arithmetic, reached from the keyboard.
class CalculatorKeyboardActions {
  const CalculatorKeyboardActions({
    required this.onCopy,
    required this.onPaste,
    required this.onInsert,
    required this.onClose,
    required this.onFlash,
  });

  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback onInsert;
  final VoidCallback onClose;
  final ValueChanged<CalculatorKey> onFlash;
}

/// Turns key presses into calculator input, the way Calculator.app does:
/// digits, `+ - * / x %`, Enter or `=` for equals, Backspace, Delete or `c`
/// to clear, Esc to clear (or close when already clear), ⌘/Ctrl+C to copy,
/// ⌘/Ctrl+V to paste. Shift+Enter puts the answer in the page's field.
///
/// Layout-proof: what the key types is read first ("+", "٣", "٪"); when the
/// Arabic layout turns a key into a letter, the physical key decides (the
/// digit row, numpad, `.`, `-`, `=`, `/`, `c`).
///
/// A barcode scanner is a keyboard too. The till's `BarcodeScanListener`
/// still receives a scan made while the calculator has focus (it listens
/// below the focus system); this handler takes back what the burst typed
/// here. Unlike the cart's `ScanBurstGuard` (two fast digits), a burst is
/// [burstLength] keys in a row each within [burstGap] — a numpad expert
/// rolling two digits must not lose one — and it covers every key, because a
/// payment-receipt QR types `/`, `=` and `c` that would divide, evaluate and
/// clear.
class CalculatorKeyboardHandler {
  CalculatorKeyboardHandler({
    required this.controller,
    this.clock = DateTime.now,
  });

  static const Duration burstGap = Duration(milliseconds: 50);
  static const int burstLength = 4;

  final CalculatorController controller;
  final DateTime Function() clock;

  DateTime? _lastKeyAt;
  int _run = 0;
  Object? _runStart;
  bool _cooling = false;

  static final Map<LogicalKeyboardKey, CalculatorKey> _numpad = {
    LogicalKeyboardKey.numpad0: CalculatorKey.zero,
    LogicalKeyboardKey.numpad1: CalculatorKey.one,
    LogicalKeyboardKey.numpad2: CalculatorKey.two,
    LogicalKeyboardKey.numpad3: CalculatorKey.three,
    LogicalKeyboardKey.numpad4: CalculatorKey.four,
    LogicalKeyboardKey.numpad5: CalculatorKey.five,
    LogicalKeyboardKey.numpad6: CalculatorKey.six,
    LogicalKeyboardKey.numpad7: CalculatorKey.seven,
    LogicalKeyboardKey.numpad8: CalculatorKey.eight,
    LogicalKeyboardKey.numpad9: CalculatorKey.nine,
    LogicalKeyboardKey.numpadDecimal: CalculatorKey.decimal,
    LogicalKeyboardKey.numpadAdd: CalculatorKey.add,
    LogicalKeyboardKey.numpadSubtract: CalculatorKey.subtract,
    LogicalKeyboardKey.numpadMultiply: CalculatorKey.multiply,
    LogicalKeyboardKey.numpadDivide: CalculatorKey.divide,
    LogicalKeyboardKey.numpadEqual: CalculatorKey.equals,
    LogicalKeyboardKey.numpadEnter: CalculatorKey.equals,
  };

  static final Map<PhysicalKeyboardKey, CalculatorKey> _physical = {
    PhysicalKeyboardKey.digit0: CalculatorKey.zero,
    PhysicalKeyboardKey.digit1: CalculatorKey.one,
    PhysicalKeyboardKey.digit2: CalculatorKey.two,
    PhysicalKeyboardKey.digit3: CalculatorKey.three,
    PhysicalKeyboardKey.digit4: CalculatorKey.four,
    PhysicalKeyboardKey.digit5: CalculatorKey.five,
    PhysicalKeyboardKey.digit6: CalculatorKey.six,
    PhysicalKeyboardKey.digit7: CalculatorKey.seven,
    PhysicalKeyboardKey.digit8: CalculatorKey.eight,
    PhysicalKeyboardKey.digit9: CalculatorKey.nine,
    PhysicalKeyboardKey.period: CalculatorKey.decimal,
    PhysicalKeyboardKey.minus: CalculatorKey.subtract,
    PhysicalKeyboardKey.equal: CalculatorKey.equals,
    PhysicalKeyboardKey.slash: CalculatorKey.divide,
    PhysicalKeyboardKey.keyC: CalculatorKey.clear,
  };

  static const Map<String, CalculatorKey> _characters = {
    '.': CalculatorKey.decimal,
    '٫': CalculatorKey.decimal,
    '+': CalculatorKey.add,
    '-': CalculatorKey.subtract,
    '−': CalculatorKey.subtract,
    '*': CalculatorKey.multiply,
    'x': CalculatorKey.multiply,
    'X': CalculatorKey.multiply,
    '×': CalculatorKey.multiply,
    '/': CalculatorKey.divide,
    '÷': CalculatorKey.divide,
    '%': CalculatorKey.percent,
    '٪': CalculatorKey.percent,
    '=': CalculatorKey.equals,
    'c': CalculatorKey.clear,
    'C': CalculatorKey.clear,
  };

  KeyEventResult handle(KeyEvent event, CalculatorKeyboardActions actions) {
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final logical = event.logicalKey;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      if (event is KeyRepeatEvent || keyboard.isAltPressed) {
        return KeyEventResult.ignored;
      }
      if (logical == LogicalKeyboardKey.keyC ||
          event.physicalKey == PhysicalKeyboardKey.keyC) {
        actions.onCopy();
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.keyV ||
          event.physicalKey == PhysicalKeyboardKey.keyV) {
        actions.onPaste();
        return KeyEventResult.handled;
      }
      // Everything else with a modifier (Ctrl+Enter checkout, Ctrl+K, …)
      // belongs to the app.
      return KeyEventResult.ignored;
    }
    if (keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }

    // Held keys: only ⌫ repeats. A held digit is a stuck key, not input, and
    // its repeat rate would read as a scanner burst anyway.
    if (event is KeyRepeatEvent) {
      if (logical == LogicalKeyboardKey.backspace) {
        _apply(CalculatorKey.backspace, actions);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (logical == LogicalKeyboardKey.escape) {
      if (controller.isEmpty) {
        actions.onClose();
      } else {
        _apply(CalculatorKey.clear, actions);
      }
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.enter ||
        logical == LogicalKeyboardKey.numpadEnter) {
      if (keyboard.isShiftPressed) {
        actions.onInsert();
        return KeyEventResult.handled;
      }
      if (_endsBurst(clock())) {
        // The scanner's own Enter: the scan was the till's, not a sum.
        return KeyEventResult.handled;
      }
      _apply(CalculatorKey.equals, actions);
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.backspace) {
      _apply(CalculatorKey.backspace, actions);
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.delete) {
      _apply(CalculatorKey.clear, actions);
      return KeyEventResult.handled;
    }

    final numpad = _numpad[logical];
    final types =
        numpad != null ||
        (event.character?.isNotEmpty ?? false) ||
        _physical.containsKey(event.physicalKey);
    if (types && _inBurst(clock())) {
      return KeyEventResult.handled;
    }
    if (numpad != null) {
      _apply(numpad, actions);
      return KeyEventResult.handled;
    }

    final character = event.character;
    if (character != null && character.isNotEmpty) {
      final digit = calculatorDigitValue(character);
      if (digit != null) {
        _apply(CalculatorKey.digit(digit), actions);
        return KeyEventResult.handled;
      }
      final key = _characters[character];
      if (key != null) {
        _apply(key, actions);
        return KeyEventResult.handled;
      }
      if (character == '(' || character == ')') {
        character == '('
            ? controller.inputOpenParen()
            : controller.inputCloseParen();
        return KeyEventResult.handled;
      }
    }

    // The key typed something we do not know (an Arabic letter, say): fall
    // back to where it sits. Shifted keys are symbols, not digits.
    if (!keyboard.isShiftPressed) {
      final key = _physical[event.physicalKey];
      if (key != null) {
        _apply(key, actions);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Whether a key arriving [now] belongs to a scanner burst. On the key that
  /// reveals one, the display goes back to how it was before the burst began.
  bool _inBurst(DateTime now) {
    final last = _lastKeyAt;
    _lastKeyAt = now;
    if (last == null || now.difference(last) > burstGap) {
      _run = 1;
      _cooling = false;
      _runStart = controller.snapshot();
      return false;
    }
    _run++;
    if (_cooling) {
      return true;
    }
    if (_run >= burstLength) {
      _cooling = true;
      final start = _runStart;
      if (start != null) {
        controller.restore(start);
      }
      return true;
    }
    return false;
  }

  /// Whether an Enter arriving [now] terminates a scanner burst.
  bool _endsBurst(DateTime now) {
    final last = _lastKeyAt;
    final ends =
        _cooling && last != null && now.difference(last) <= burstGap * 2;
    _lastKeyAt = null;
    _cooling = false;
    _run = 0;
    return ends;
  }

  void _apply(CalculatorKey key, CalculatorKeyboardActions actions) {
    key.applyTo(controller);
    actions.onFlash(key);
  }
}
