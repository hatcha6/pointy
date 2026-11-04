import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/units.dart';

/// The field's text as a threshold to save: null for blank (the variant is not
/// watched), the number otherwise. Only call it on text the field validated.
double? lowStockThresholdFromText(String text) {
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : parseDecimal(trimmed);
}

/// A saved threshold as the field's starting text; blank when there is none.
String lowStockThresholdText(double? threshold) =>
    threshold == null ? '' : formatQuantity(threshold);

/// A variant's low-stock threshold: the shop-wide count, in base units, at or
/// below which the variant raises a low-stock notification.
///
/// Optional on purpose. Blank is the answer "do not watch this one" — it
/// raises neither a low-stock nor an out-of-stock alert — and is what every
/// variant starts as, so a shop is only told about what it chose to track.
class LowStockThresholdField extends StatelessWidget {
  const LowStockThresholdField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.appliesToEveryVariant = false,
  });

  final TextEditingController controller;
  final bool enabled;

  /// On a new product that generates several variants: the one number is
  /// written to each of them, and each can be changed on its own later.
  final bool appliesToEveryVariant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextFormField(
      key: const ValueKey('variant_low_stock_threshold_field'),
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textInputAction: TextInputAction.next,
      inputFormatters: [DecimalTextInputFormatter()],
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (value) {
        final text = value?.trim() ?? '';
        if (text.isEmpty) {
          return null;
        }
        final parsed = parseDecimal(text);
        return parsed == null || parsed < 0 ? l10n.invalidNumber : null;
      },
      decoration: InputDecoration(
        labelText: l10n.lowStockThresholdLabel,
        helperText: appliesToEveryVariant
            ? l10n.lowStockThresholdGeneratedHelper
            : l10n.lowStockThresholdHelper,
        helperMaxLines: 2,
        prefixIcon: const Icon(Icons.notifications_active_outlined),
      ),
    );
  }
}
