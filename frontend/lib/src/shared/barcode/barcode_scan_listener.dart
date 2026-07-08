import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Global hardware-keyboard listener for USB/Bluetooth barcode wedges, which
/// type their payload as a fast key burst ending in Enter/Tab.
///
/// It ONLY ever reports a completed scan (via [onBarcodeScanned]) or an
/// arrow-key press (via [onArrowKey]). It deliberately never turns loose
/// keystrokes into a quantity, so a scan — being nothing but keyboard input —
/// can never overwrite a cart/draft line's quantity. Slow, deliberate quantity
/// entry lives behind an explicit line focus in the cart/draft panes instead.
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
    this.onArrowKey,
  });

  final Widget child;
  final ValueChanged<String> onBarcodeScanned;
  final bool enabled;
  final int minLength;
  final Duration maxInterKeyDelay;
  final bool ignoreTextInputFocus;
  final bool requireCurrentRoute;

  /// Arrow-key presses (with the same focus/route guards as scanning). Return
  /// true to consume the event — e.g. cycling the last scanned line's unit —
  /// or false to let focus traversal proceed.
  final bool Function(LogicalKeyboardKey key)? onArrowKey;

  @override
  State<BarcodeScanListener> createState() => _BarcodeScanListenerState();
}

class _BarcodeScanListenerState extends State<BarcodeScanListener> {
  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyAt;

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

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
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

    // A gap longer than a scanner's inter-key burst means anything already
    // buffered was not part of this scan — drop it so a following arrow (or a
    // fresh scan) starts from a clean buffer.
    final now = DateTime.now();
    final lastKeyAt = _lastKeyAt;
    if (lastKeyAt != null &&
        now.difference(lastKeyAt) > widget.maxInterKeyDelay) {
      _buffer.clear();
      _lastKeyAt = null;
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

    _buffer.write(character);
    _lastKeyAt = now;
    return false;
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
  }
}
