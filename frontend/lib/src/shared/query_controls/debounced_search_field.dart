import 'dart:async';

import 'package:flutter/material.dart';

class DebouncedSearchField extends StatefulWidget {
  const DebouncedSearchField({
    super.key,
    required this.value,
    required this.hintText,
    required this.clearTooltip,
    required this.onChanged,
    this.debounceDuration = const Duration(milliseconds: 350),
  });

  final String value;
  final String hintText;
  final String clearTooltip;
  final ValueChanged<String> onChanged;
  final Duration debounceDuration;

  @override
  State<DebouncedSearchField> createState() => _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends State<DebouncedSearchField> {
  late final TextEditingController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant DebouncedSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: TextField(
        controller: _controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hintText,
          filled: true,
          fillColor: Colors.transparent,
          prefixIcon: Icon(Icons.search, color: colorScheme.primary),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: widget.clearTooltip,
                  onPressed: () {
                    _controller.clear();
                    _emitNow('');
                  },
                  icon: const Icon(Icons.close),
                ),
          border: _fieldBorder(colorScheme.outlineVariant),
          enabledBorder: _fieldBorder(colorScheme.outlineVariant),
          focusedBorder: _fieldBorder(colorScheme.primary, width: 1.4),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 15,
          ),
        ),
        onChanged: _emitDebounced,
        onSubmitted: _emitNow,
      ),
    );
  }

  OutlineInputBorder _fieldBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  void _emitDebounced(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(widget.debounceDuration, () {
      widget.onChanged(value.trim());
    });
  }

  void _emitNow(String value) {
    setState(() {});
    _debounce?.cancel();
    widget.onChanged(value.trim());
  }
}
