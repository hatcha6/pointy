import 'dart:async';

import 'package:flutter/material.dart';

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

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: TextField(
        key: widget.fieldKey,
        controller: _controller,
        focusNode: widget.focusNode,
        enabled: widget.enabled,
        autofocus: widget.autofocus,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hintText,
          filled: true,
          fillColor: Colors.transparent,
          prefixIcon: Icon(Icons.search, color: colors.primaryStrong),
          prefixIconConstraints: const BoxConstraints.tightFor(
            width: 48,
            height: 48,
          ),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, child) {
              if (value.text.isEmpty) {
                return const SizedBox.shrink();
              }

              return IconButton(
                tooltip: widget.clearTooltip,
                onPressed: widget.enabled
                    ? () {
                        _setControllerText('');
                        _emitNow('');
                      }
                    : null,
                icon: child!,
              );
            },
            child: const Icon(Icons.close),
          ),
          suffixIconConstraints: const BoxConstraints.tightFor(
            width: 48,
            height: 48,
          ),
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
