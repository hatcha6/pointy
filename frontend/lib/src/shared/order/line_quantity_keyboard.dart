import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../barcode/scan_burst_guard.dart';

/// What the focused-line keyboard asks its pane to do.
class LineQuantityActions {
  const LineQuantityActions({
    required this.onPendingChanged,
    required this.onIncrement,
    required this.onDecrement,
    required this.onCommit,
    required this.onDismiss,
  });

  /// The half-typed quantity changed: repaint its banner.
  final VoidCallback onPendingChanged;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  /// Enter: the typed quantity, or null when nothing (or nothing readable)
  /// was typed — the pane decides whether Enter then also moves on.
  final ValueChanged<double?> onCommit;

  /// Esc with nothing pending: the person is done with this line.
  final VoidCallback onDismiss;
}

/// The keyboard of a selected order line — the POS cart's and the purchase
/// draft's, which are the same job and were the same 200 lines twice.
///
/// Tap a line to select it, type a quantity (shown in a banner), Enter applies
/// it; `+`/`-` step, Backspace edits, Esc clears the entry, then the line.
///
/// The traps it exists to get right, once:
/// * **A scanner is a keyboard.** Digits faster than a person can type are a
///   wedge burst — [ScanBurstGuard] rolls them back and swallows the Enter
///   that ends them, so a scan never becomes a quantity of 6291041500213.
/// * **Modifier chords are not quantities.** Ctrl/⌘/Alt combinations are left
///   to bubble to the screen (Ctrl+Enter submits, Ctrl+K searches).
/// * **A field inside the line owns its own digits.** Keys are only taken
///   while the line's own focus node holds *primary* focus; the moment the
///   cost or expiry field is focused, they belong to that field.
/// * **Layouts disagree about digits.** French AZERTY types `&é"'` on the
///   unshifted digit row and a Mac set to Arabic types `١٢٣`; neither is a
///   `LogicalKeyboardKey.digitN`. Digits are read from the character, the
///   numpad and the physical row, in that order.
class LineQuantityEntry {
  LineQuantityEntry({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final ScanBurstGuard _burstGuard = ScanBurstGuard();
  String _pending = '';

  String get pending => _pending;

  /// Drops a half-typed quantity (a structural change to the order, focus
  /// leaving the line). Returns whether there was one.
  bool clear() {
    if (_pending.isEmpty) {
      return false;
    }
    _pending = '';
    return true;
  }

  KeyEventResult handle(
    FocusNode node,
    KeyEvent event,
    LineQuantityActions actions,
  ) {
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (!node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    final digit = quantityDigitFor(event);
    if (digit != null) {
      return _append(digit, actions, maxLength: 7);
    }
    if (isQuantityDecimalKey(event)) {
      // Fractional entry (2.5 of anything) is the person's choice, for every
      // product; one decimal point at most.
      if (_pending.contains('.')) {
        return KeyEventResult.handled;
      }
      return _append(_pending.isEmpty ? '0.' : '.', actions, maxLength: 6);
    }
    if (key == LogicalKeyboardKey.backspace) {
      if (_pending.isEmpty) {
        return KeyEventResult.ignored;
      }
      _pending = _pending.substring(0, _pending.length - 1);
      actions.onPendingChanged();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_burstGuard.shouldSwallowCommit(_clock())) {
        // Tail of a scanner burst (reaches here only when the scan listener is
        // disabled or the code was too short) — never commit it.
        return KeyEventResult.handled;
      }
      final typed = double.tryParse(_pending);
      clear();
      actions.onPendingChanged();
      actions.onCommit(typed != null && typed > 0 ? typed : null);
      return KeyEventResult.handled;
    }
    if (isIncrementKey(event)) {
      clear();
      actions.onPendingChanged();
      actions.onIncrement();
      return KeyEventResult.handled;
    }
    if (isDecrementKey(event)) {
      clear();
      actions.onPendingChanged();
      actions.onDecrement();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (clear()) {
        // First Esc only clears the half-typed number; the line stays
        // selected so it can be retyped.
        actions.onPendingChanged();
      } else {
        actions.onDismiss();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _append(
    String text,
    LineQuantityActions actions, {
    required int maxLength,
  }) {
    final rollback = _burstGuard.onDigit(_pending, _clock());
    if (rollback != null) {
      // A wedge is typing, not a person: back to the pre-burst entry, and the
      // key is swallowed. The scan itself is BarcodeScanListener's job.
      if (_pending != rollback) {
        _pending = rollback;
        actions.onPendingChanged();
      }
      return KeyEventResult.handled;
    }
    if (_pending.length < maxLength) {
      _pending = '$_pending$text';
      actions.onPendingChanged();
    }
    return KeyEventResult.handled;
  }
}

/// The digit a key event types, whatever the keyboard layout — or null.
String? quantityDigitFor(KeyEvent event) {
  final character = event.character;
  if (character != null && character.runes.length == 1) {
    final rune = character.runes.single;
    if (rune >= 0x30 && rune <= 0x39) {
      return character;
    }
    // Arabic-Indic (٠–٩) and Eastern Arabic-Indic (۰–۹) digits.
    if (rune >= 0x0660 && rune <= 0x0669) {
      return String.fromCharCode(0x30 + rune - 0x0660);
    }
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      return String.fromCharCode(0x30 + rune - 0x06F0);
    }
  }
  final logical =
      _numpadDigits[event.logicalKey] ?? _rowDigits[event.logicalKey];
  if (logical != null) {
    return logical;
  }
  // The unshifted digit row on a layout that puts symbols there (AZERTY).
  // Shifted, it is a symbol on QWERTY ("!"), so Shift keeps it out.
  if (!HardwareKeyboard.instance.isShiftPressed) {
    return _physicalDigits[event.physicalKey];
  }
  return null;
}

bool isQuantityDecimalKey(KeyEvent event) =>
    event.logicalKey == LogicalKeyboardKey.period ||
    event.logicalKey == LogicalKeyboardKey.numpadDecimal ||
    const {'.', '٫'}.contains(event.character);

bool isIncrementKey(KeyEvent event) =>
    event.logicalKey == LogicalKeyboardKey.numpadAdd ||
    event.logicalKey == LogicalKeyboardKey.add ||
    // `=` is the unshifted `+` key; a till shortcut nobody should need Shift
    // for.
    event.logicalKey == LogicalKeyboardKey.equal ||
    event.character == '+';

bool isDecrementKey(KeyEvent event) =>
    event.logicalKey == LogicalKeyboardKey.numpadSubtract ||
    event.logicalKey == LogicalKeyboardKey.minus ||
    event.character == '-';

final Map<LogicalKeyboardKey, String> _rowDigits = {
  LogicalKeyboardKey.digit0: '0',
  LogicalKeyboardKey.digit1: '1',
  LogicalKeyboardKey.digit2: '2',
  LogicalKeyboardKey.digit3: '3',
  LogicalKeyboardKey.digit4: '4',
  LogicalKeyboardKey.digit5: '5',
  LogicalKeyboardKey.digit6: '6',
  LogicalKeyboardKey.digit7: '7',
  LogicalKeyboardKey.digit8: '8',
  LogicalKeyboardKey.digit9: '9',
};

final Map<LogicalKeyboardKey, String> _numpadDigits = {
  LogicalKeyboardKey.numpad0: '0',
  LogicalKeyboardKey.numpad1: '1',
  LogicalKeyboardKey.numpad2: '2',
  LogicalKeyboardKey.numpad3: '3',
  LogicalKeyboardKey.numpad4: '4',
  LogicalKeyboardKey.numpad5: '5',
  LogicalKeyboardKey.numpad6: '6',
  LogicalKeyboardKey.numpad7: '7',
  LogicalKeyboardKey.numpad8: '8',
  LogicalKeyboardKey.numpad9: '9',
};

final Map<PhysicalKeyboardKey, String> _physicalDigits = {
  PhysicalKeyboardKey.digit0: '0',
  PhysicalKeyboardKey.digit1: '1',
  PhysicalKeyboardKey.digit2: '2',
  PhysicalKeyboardKey.digit3: '3',
  PhysicalKeyboardKey.digit4: '4',
  PhysicalKeyboardKey.digit5: '5',
  PhysicalKeyboardKey.digit6: '6',
  PhysicalKeyboardKey.digit7: '7',
  PhysicalKeyboardKey.digit8: '8',
  PhysicalKeyboardKey.digit9: '9',
};
