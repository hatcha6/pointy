import 'package:flutter/material.dart';

class ReceiptToggleRow extends StatelessWidget {
  const ReceiptToggleRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.tooltip,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final String tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CheckboxListTile(
        key: const ValueKey('payment_receipt_toggle'),
        value: value,
        onChanged: (nextValue) => onChanged(nextValue ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
