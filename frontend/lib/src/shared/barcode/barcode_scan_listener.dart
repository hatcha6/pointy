import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Marks a text field as a deliberate wedge target: a field the user focuses
/// ON PURPOSE to scan INTO (e.g. a supplier-invoice number scanned off a
/// printed invoice). [BarcodeScanListener] leaves bursts typed into an exempt
/// field alone instead of intercepting them as product scans.
class ScanWedgeTarget extends StatelessWidget {
  const ScanWedgeTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Global hardware-keyboard listener for USB/Bluetooth barcode wedges, which
/// type their payload as a fast key burst ending in Enter/Tab.
///
/// It ONLY ever reports a completed scan (via [onBarcodeScanned]) or an
/// arrow-key press (via [onArrowKey]). It deliberately never turns loose
/// keystrokes into a quantity, so a scan — being nothing but keyboard input —
/// can never overwrite a cart/draft line's quantity. Slow, deliberate quantity
/// entry lives behind an explicit line focus in the cart/draft panes instead
/// (guarded there by ScanBurstGuard against the same wedge bursts).
///
/// Robustness rules, each closing a way a scan could leak into a screen:
/// - **A focused text field does not blind the listener.** The burst lands in
///   the field while it happens, but the field's value is snapshotted at the
///   burst's first key and restored when the terminator arrives; the
///   terminator is consumed (no onSubmitted) and the payload is reported as a
///   scan. Slow human typing never matches the burst timing and is untouched.
///   Fields wrapped in [ScanWedgeTarget] opt out and receive the raw wedge
///   input, as before.
/// - **Being disabled does not open a hole.** While [enabled] is false (mid
///   checkout, mid barcode-resolve) bursts are still tracked, fields still
///   restored, and terminators still consumed — only the payload is dropped,
///   so a too-early rescan is safely ignored instead of leaking keystrokes.
/// - **A stale buffer never submits.** A terminator only completes a scan if
///   it follows the last burst key within [maxInterKeyDelay]; an Enter pressed
///   later is normal typing.
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
    @visibleForTesting this.clock = DateTime.now,
  });

  final Widget child;
  final ValueChanged<String> onBarcodeScanned;
  final bool enabled;
  final int minLength;
  final Duration maxInterKeyDelay;

  /// When true (the default), a focused text field keeps its normal typing
  /// behavior: only completed scanner BURSTS are intercepted and undone; loose
  /// keys, arrows, and Enter presses belong to the field.
  final bool ignoreTextInputFocus;
  final bool requireCurrentRoute;

  /// Arrow-key presses (with the same focus/route guards as scanning). Return
  /// true to consume the event — e.g. cycling the last scanned line's unit —
  /// or false to let focus traversal proceed.
  final bool Function(LogicalKeyboardKey key)? onArrowKey;

  /// Injectable time source so tests can drive the burst timing.
  final DateTime Function() clock;

  @override
  State<BarcodeScanListener> createState() => _BarcodeScanListenerState();
}

class _BarcodeScanListenerState extends State<BarcodeScanListener> {
  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyAt;

  // Snapshot of the focused text field taken at the burst's first key, so a
  // completed scan can put the field back exactly as it was.
  TextEditingController? _fieldController;
  TextEditingValue? _fieldValueBeforeBurst;

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
    if (event is! KeyDownEvent || _shouldIgnoreForRoute()) {
      return false;
    }

    final focusedEditable = _focusedEditable();
    if (focusedEditable != null && _isExemptWedgeTarget()) {
      // The user focused this field to scan into it — stay out of the way.
      _reset();
      return false;
    }

    final now = widget.clock();

    if (_terminatorKeys.contains(event.logicalKey)) {
      return _submitBuffer(now);
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
    final lastKeyAt = _lastKeyAt;
    if (lastKeyAt != null &&
        now.difference(lastKeyAt) > widget.maxInterKeyDelay) {
      _clearBuffer();
    }

    if (_arrowKeys.contains(event.logicalKey)) {
      // Arrows inside a text field are cursor movement, never a shortcut.
      final onArrowKey = widget.onArrowKey;
      if (onArrowKey != null && focusedEditable == null && _buffer.isEmpty) {
        return onArrowKey(event.logicalKey);
      }
      return false;
    }

    final character = event.character;
    if (character == null || character.runes.length != 1) {
      return false;
    }

    if (focusedEditable != null) {
      final controller = focusedEditable.controller;
      if (_buffer.isEmpty || !identical(controller, _fieldController)) {
        // First key of a potential burst into this field (or focus moved
        // mid-burst): snapshot the field as it is BEFORE this key lands, so a
        // completed scan can restore it. The key itself proceeds normally —
        // if no burst follows, this was just typing.
        _clearBuffer();
        _fieldController = controller;
        _fieldValueBeforeBurst = controller.value;
      }
    } else if (_fieldController != null) {
      // Focus left the field mid-buffer; whatever was typed there stays.
      _clearBuffer();
    }

    _buffer.write(character);
    _lastKeyAt = now;
    return false;
  }

  bool _submitBuffer(DateTime now) {
    final barcode = _buffer.toString().trim();
    final lastKeyAt = _lastKeyAt;
    final controller = _fieldController;
    final valueBeforeBurst = _fieldValueBeforeBurst;
    _reset();

    if (barcode.length < widget.minLength) {
      return false;
    }
    // A real wedge fires its terminator on the heels of the last character; an
    // Enter pressed after a pause is the user submitting whatever they typed.
    if (lastKeyAt == null ||
        now.difference(lastKeyAt) > widget.maxInterKeyDelay) {
      return false;
    }

    if (controller != null && valueBeforeBurst != null) {
      // The burst landed in a focused text field — put the field back exactly
      // as it was, but only if it still ends with what we buffered (input
      // formatters or programmatic edits may have diverged; never clobber a
      // value we don't recognize).
      if (controller.text.endsWith(barcode)) {
        controller.value = valueBeforeBurst;
      } else if (widget.ignoreTextInputFocus) {
        // Field diverged from the keystream (heavy formatting): treat as
        // normal typing rather than guessing at a repair.
        return false;
      }
    }

    if (widget.enabled) {
      widget.onBarcodeScanned(barcode);
    }
    // Consume the terminator either way: a scan mid-checkout/mid-resolve is
    // dropped, not converted into an Enter aimed at whatever has focus.
    return true;
  }

  /// The focused EditableText, unless field interception is disabled.
  EditableText? _focusedEditable() {
    if (!widget.ignoreTextInputFocus) {
      return null;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) {
      return null;
    }
    final focusedWidget = focusedContext.widget;
    if (focusedWidget is EditableText) {
      return focusedWidget;
    }
    return focusedContext.findAncestorWidgetOfExactType<EditableText>();
  }

  bool _isExemptWedgeTarget() {
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    return focusedContext?.findAncestorWidgetOfExactType<ScanWedgeTarget>() !=
        null;
  }

  bool _shouldIgnoreForRoute() {
    if (!widget.requireCurrentRoute) {
      return false;
    }
    return ModalRoute.of(context)?.isCurrent == false;
  }

  void _clearBuffer() {
    _buffer.clear();
    _lastKeyAt = null;
    _fieldController = null;
    _fieldValueBeforeBurst = null;
  }

  void _reset() {
    _clearBuffer();
  }
}
