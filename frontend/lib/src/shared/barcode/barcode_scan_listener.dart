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
  });

  final Widget child;
  final ValueChanged<String> onBarcodeScanned;
  final bool enabled;
  final int minLength;
  final Duration maxInterKeyDelay;
  final bool ignoreTextInputFocus;
  final bool requireCurrentRoute;

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
