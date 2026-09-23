import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/design.dart';

class DebouncedSearchField extends StatefulWidget {
  const DebouncedSearchField({
    super.key,
    required this.value,
    required this.hintText,
    required this.clearTooltip,
    required this.onChanged,
    this.onSubmitted,
    this.debounceDuration = const Duration(milliseconds: 350),
    this.enabled = true,
    this.autofocus = false,
    this.fieldKey,
    this.focusNode,
    this.resetSignal,
    this.labelText,
    this.prefix,
    this.prefixConstraints,
    this.trailingBuilder,
    this.keyboardType,
    this.inputFormatters,
    this.textDirection,
  });

  final String value;
  final String hintText;
  final String clearTooltip;
  final ValueChanged<String> onChanged;
  final FutureOr<bool> Function(String value)? onSubmitted;
  final Duration debounceDuration;
  final bool enabled;
  final bool autofocus;
  final Key? fieldKey;

  /// An externally-owned focus node, so a caller can programmatically pull
  /// focus back to the field (e.g. the POS returning focus to catalog search
  /// after a sale). The owner is responsible for disposing it; when null the
  /// [TextField] manages its own node as before.
  final FocusNode? focusNode;

  /// An externally-owned signal that clears the field and cancels any pending
  /// debounce when it fires. The POS uses it after a barcode scan so the
  /// scanner's key burst (which momentarily lands in the field and queues a
  /// debounced search) can't push the code back into the field. The owner
  /// disposes it; when null the field behaves as before.
  final Listenable? resetSignal;

  /// A label that names what the field holds, for a field that is more than
  /// a list filter — the till's top-up box, where it says "card number".
  final String? labelText;

  /// Replaces the search icon in front of the text. The top-up box puts a
  /// control there (which kind of number this is) rather than an icon.
  final Widget? prefix;

  /// Box for [prefix]. Ignored without one: the default icon keeps its own.
  final BoxConstraints? prefixConstraints;

  /// An action after the clear button, handed a callback that submits what
  /// is in the field right now — through the same path as the keyboard's
  /// search key, so a tap cannot act on text the debounce has not reported.
  final Widget Function(BuildContext context, VoidCallback submit)?
  trailingBuilder;

  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// The direction of the text itself, e.g. left-to-right for a number
  /// typed into an Arabic screen. The field's own layout follows the page.
  final TextDirection? textDirection;

  @override
  State<DebouncedSearchField> createState() => _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends State<DebouncedSearchField> {
  late final TextEditingController _controller;
  Timer? _debounce;
  int _inputRevision = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    widget.resetSignal?.addListener(_handleReset);
  }

  @override
  void didUpdateWidget(covariant DebouncedSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetSignal != oldWidget.resetSignal) {
      oldWidget.resetSignal?.removeListener(_handleReset);
      widget.resetSignal?.addListener(_handleReset);
    }
    if (widget.value != oldWidget.value) {
      _inputRevision++;
      _debounce?.cancel();
      if (widget.value != _controller.text) {
        _setControllerText(widget.value);
      }
    }
  }

  @override
  void dispose() {
    widget.resetSignal?.removeListener(_handleReset);
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Hard-reset: drop the text and cancel any in-flight debounce (bumping the
  /// revision so a timer already scheduled is ignored when it fires). The query
  /// is reset to empty after the frame — deferred so this can be invoked from
  /// within a view-model notification without re-entrancy. See
  /// [DebouncedSearchField.resetSignal].
  void _handleReset() {
    _debounce?.cancel();
    _inputRevision++;
    if (_controller.text.isNotEmpty) {
      _setControllerText('');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onChanged('');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    // No clipBehavior: a clipped Material becomes a PhysicalShape, which is a
    // saveLayer on every list screen's resting tree. Nothing inside the field
    // reaches the rounded corners, so the shape only needs painting.
    //
    // Its own layer: the cursor blinks twice a second for as long as the
    // field has focus (the POS search rests focused), and every keystroke
    // repaints it; neither should re-record the page around it.
    return RepaintBoundary(
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        child: TextField(
          key: widget.fieldKey,
          controller: _controller,
          focusNode: widget.focusNode,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          textDirection: widget.textDirection,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: widget.labelText,
            hintText: widget.hintText,
            filled: true,
            fillColor: Colors.transparent,
            prefixIcon:
                widget.prefix ??
                Icon(Icons.search, color: colors.primaryStrong),
            prefixIconConstraints: widget.prefix == null
                ? const BoxConstraints.tightFor(width: 48, height: 48)
                : widget.prefixConstraints,
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) {
                final clear = value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: widget.clearTooltip,
                        onPressed: widget.enabled
                            ? () {
                                _setControllerText('');
                                _emitNow('');
                              }
                            : null,
                        icon: child!,
                      );
                final trailing = widget.trailingBuilder?.call(
                  context,
                  _submitCurrent,
                );
                if (trailing == null) {
                  return clear ?? const SizedBox.shrink();
                }
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [?clear, trailing],
                );
              },
              child: const Icon(Icons.close),
            ),
            // A trailing action makes the slot one or two buttons wide
            // depending on whether there is text to clear, so it may grow.
            suffixIconConstraints: widget.trailingBuilder == null
                ? const BoxConstraints.tightFor(width: 48, height: 48)
                : const BoxConstraints(minWidth: 48, minHeight: 48),
            border: _fieldBorder(colors.line),
            enabledBorder: _fieldBorder(colors.line),
            focusedBorder: _fieldBorder(colors.primaryStrong, width: 1.4),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 15,
            ),
          ),
          onChanged: _emitDebounced,
          onSubmitted: _emitSubmitted,
        ),
      ),
    );
  }

  void _setControllerText(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  OutlineInputBorder _fieldBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  void _emitDebounced(String value) {
    final revision = ++_inputRevision;
    final nextValue = value.trim();
    _debounce?.cancel();
    _debounce = Timer(widget.debounceDuration, () {
      if (revision == _inputRevision) {
        widget.onChanged(nextValue);
      }
    });
  }

  void _emitNow(String value) {
    _inputRevision++;
    _debounce?.cancel();
    widget.onChanged(value.trim());
  }

  void _submitCurrent() => _emitSubmitted(_controller.text);

  Future<void> _emitSubmitted(String value) async {
    final submittedValue = value.trim();
    final revision = ++_inputRevision;
    _debounce?.cancel();
    if (submittedValue != value) {
      _setControllerText(submittedValue);
    }

    final onSubmitted = widget.onSubmitted;
    if (onSubmitted == null || submittedValue.isEmpty) {
      widget.onChanged(submittedValue);
      return;
    }

    final shouldClear = await onSubmitted(submittedValue);
    if (!mounted || revision != _inputRevision) {
      return;
    }
    if (shouldClear) {
      _setControllerText('');
      widget.onChanged('');
    } else {
      widget.onChanged(submittedValue);
    }
  }
}
