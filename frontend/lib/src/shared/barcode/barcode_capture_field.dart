import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'barcode_capture_controller.dart';

class BarcodeCaptureField extends StatelessWidget {
  const BarcodeCaptureField({
    super.key,
    required this.controller,
    required this.labelText,
    required this.hintText,
    required this.clearTooltip,
    required this.focusTooltip,
    required this.onSubmitted,
    this.enabled = true,
    this.autofocus = false,
  });

  final BarcodeCaptureController controller;
  final String labelText;
  final String hintText;
  final String clearTooltip;
  final String focusTooltip;
  final FutureOr<void> Function(String barcode) onSubmitted;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return TextField(
          key: const ValueKey('barcode_capture_field'),
          controller: controller.textController,
          focusNode: controller.focusNode,
          enabled: enabled,
          autofocus: autofocus,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.start,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'[\n\r\t]')),
          ],
          decoration: InputDecoration(
            labelText: labelText,
            hintText: hintText,
            prefixIcon: const Icon(Icons.qr_code_scanner_outlined),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.value.isNotEmpty)
                  IconButton(
                    tooltip: clearTooltip,
                    onPressed: enabled ? controller.clear : null,
                    icon: const Icon(Icons.clear),
                  ),
                IconButton(
                  tooltip: focusTooltip,
                  onPressed: enabled ? controller.requestFocus : null,
                  icon: const Icon(Icons.center_focus_strong_outlined),
                ),
              ],
            ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => controller.syncTextChange(),
          onSubmitted: enabled ? _submit : null,
        );
      },
    );
  }

  Future<void> _submit(String _) async {
    final barcode = controller.takeSubmittedValue();
    if (barcode.isEmpty) {
      return;
    }
    await onSubmitted(barcode);
    controller.requestFocus();
  }
}
