import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/tracking/gtin.dart';

/// What a GTIN field holds, ready to send: the GTIN out of a scanned
/// DataMatrix, or the digits as typed (the server stores GTIN-14 either way).
String gtinFieldValue(String raw) => gtinFromGs1Scan(raw) ?? raw.trim();

/// A variant's GS1 trade-item number (§6.3): the key a DataMatrix on a
/// pharmaceutical pack resolves to this variant by.
///
/// Checked as it is typed — length and the check digit — because a typo here
/// is a pack that never scans, and nobody finds out until a cashier is
/// holding it. A scan wedge pointed at the field reads the box itself: the
/// whole element string arrives, and the GTIN is taken out of it.
class VariantGtinField extends StatelessWidget {
  const VariantGtinField({
    super.key,
    required this.controller,
    this.errorText,
    this.enabled = true,
    this.onChanged,
  });

  final TextEditingController controller;

  /// The server's refusal (another product's GTIN), already in Arabic.
  final String? errorText;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ScanWedgeTarget(
      child: TextFormField(
        key: const ValueKey('variant_gtin_field'),
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        inputFormatters: [
          // Digits and the separators people type between printed groups —
          // plus what a scanned element string carries — and nothing else.
          FilteringTextInputFormatter.allow(RegExp(r'[0-9\s\-\]A-Za-z\x1d]')),
        ],
        autovalidateMode: AutovalidateMode.onUserInteraction,
        validator: (value) {
          final text = gtinFieldValue(value ?? '');
          final problem = gtinProblem(text);
          return problem == null ? null : gtinProblemMessage(l10n, problem);
        },
        onChanged: onChanged,
        onFieldSubmitted: (value) {
          final scanned = gtinFromGs1Scan(value);
          if (scanned != null) {
            controller.text = scanned;
            onChanged?.call(scanned);
          }
        },
        decoration: InputDecoration(
          labelText: l10n.variantGtinLabel,
          helperText: l10n.variantGtinHelper,
          helperMaxLines: 2,
          errorText: errorText,
          prefixIcon: const Icon(Icons.qr_code_2_outlined),
        ),
      ),
    );
  }
}
