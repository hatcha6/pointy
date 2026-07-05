import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BarcodeScanListener extends StatefulWidget {
  const BarcodeScanListener({
    super.key,
    required this.child,
    required this.onBarcodeScanned,
    this.enabled = true,
    this.minLength = 4,
    this.maxInterKeyDelay = const Duration(milliseconds: 80),
    this.ignoreTextInputFocus = true,
    this.requireCurrentRoute = true,
    this.onDigitsTyped,
    this.onArrowKey,
    this.humanDigitDelay = const Duration(milliseconds: 160),
  });

  final Widget child;
  final ValueChanged<String> onBarcodeScanned;
  final bool enabled;
  final int minLength;
  final Duration maxInterKeyDelay;
  final bool ignoreTextInputFocus;
  final bool requireCurrentRoute;

  /// Digits (or a decimal point) typed by a HUMAN on the keyboard/numpad
  /// (never part of a scanner burst — a scanner's keys arrive faster than
  /// [humanDigitDelay] and end in a terminator). Powers the scan-then-type
  /// quantity flow: each slow keystroke is reported as its own chunk, so the
  /// receiver accumulates "1","2" → 12, or "2",".","5" → 2.5.
  final ValueChanged<String>? onDigitsTyped;

  /// Arrow-key presses (with the same focus/route guards as scanning). Return
  /// true to consume the event — e.g. cycling the last scanned line's unit —
  /// or false to let focus traversal proceed.
  final bool Function(LogicalKeyboardKey key)? onArrowKey;

  /// How long a digit must sit alone in the buffer before it counts as human
  /// typing. Must be comfortably above [maxInterKeyDelay] so a scanner burst in
  /// progress never fires it.
  final Duration humanDigitDelay;

  @override
  State<BarcodeScanListener> createState() => _BarcodeScanListenerState();
}

class _BarcodeScanListenerState extends State<BarcodeScanListener> {
  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyAt;
  Timer? _humanDigitTimer;

  static final _terminatorKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.tab,
  };

  static final _arrowKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  // Human quantities are short; a longer terminator-less digit string is far
  // more likely a mis-configured scanner than a cashier typing.
  static const _maxHumanDigits = 4;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _humanDigitTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BarcodeScanListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!widget.enabled ||
        event is! KeyDownEvent ||
        _shouldIgnoreForRoute() ||
        _shouldIgnoreForFocusedInput()) {
      return false;
    }

    if (_terminatorKeys.contains(event.logicalKey)) {
      return _submitBuffer();
    }

    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      _reset();
      return false;
    }

    final onArrowKey = widget.onArrowKey;
    if (onArrowKey != null &&
        _arrowKeys.contains(event.logicalKey) &&
        _buffer.isEmpty) {
      return onArrowKey(event.logicalKey);
    }

    final character = event.character;
    if (character == null || character.runes.length != 1) {
      return false;
    }

    final now = DateTime.now();
    final lastKeyAt = _lastKeyAt;
    if (lastKeyAt != null &&
        now.difference(lastKeyAt) > widget.maxInterKeyDelay) {
      _buffer.clear();
    }

    _buffer.write(character);
    _lastKeyAt = now;
    _scheduleHumanDigitFlush();
    return false;
  }

  /// A scanner burst keeps restarting this timer (keys < [maxInterKeyDelay]
  /// apart) until its terminator submits and resets; only keys typed at human
  /// speed live long enough to flush.
  void _scheduleHumanDigitFlush() {
    _humanDigitTimer?.cancel();
    if (widget.onDigitsTyped == null) {
      return;
    }
    final pending = _buffer.toString();
    if (pending.isEmpty ||
        pending.length > _maxHumanDigits ||
        !_isQuantityChunk(pending)) {
      return;
    }
    _humanDigitTimer = Timer(widget.humanDigitDelay, _flushHumanDigits);
  }

  void _flushHumanDigits() {
    final digits = _buffer.toString();
    if (digits.isEmpty || digits.length > _maxHumanDigits) {
      return;
    }
    if (!_isQuantityChunk(digits)) {
      return;
    }
    _reset();
    widget.onDigitsTyped?.call(digits);
  }

  // Digits plus the decimal point — the receiver decides whether the line's
  // unit actually accepts fractions.
  static bool _isQuantityChunk(String value) {
    for (final code in value.codeUnits) {
      final isDigit = code >= 0x30 && code <= 0x39;
      if (!isDigit && code != 0x2e) {
        return false;
      }
    }
    return true;
  }

  bool _submitBuffer() {
    final barcode = _buffer.toString().trim();
    _reset();
    if (barcode.length < widget.minLength) {
      return false;
    }
    widget.onBarcodeScanned(barcode);
    return true;
  }

  bool _shouldIgnoreForFocusedInput() {
    if (!widget.ignoreTextInputFocus) {
      return false;
    }

    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) {
      return false;
    }

    return focusedContext.widget is EditableText ||
        focusedContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _shouldIgnoreForRoute() {
    if (!widget.requireCurrentRoute) {
      return false;
    }
    return ModalRoute.of(context)?.isCurrent == false;
  }

  void _reset() {
    _buffer.clear();
    _lastKeyAt = null;
    _humanDigitTimer?.cancel();
    _humanDigitTimer = null;
  }
}
