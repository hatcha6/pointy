import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../data/models/stock_count_draft.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Counting a shelf whose articles have names (§6.6).
///
/// No keypad, deliberately, and this is the whole point of the surface: for a
/// serialized variant a *number* is not an answer. Two handsets of one model
/// are not interchangeable, and "4" does not say which four. So the counter
/// scans, and what they see back is their own progress — never what the system
/// expected, because a count that tells you the answer is a search.
class StockCountScanShelfPanel extends StatelessWidget {
  const StockCountScanShelfPanel({
    super.key,
    required this.variant,
    required this.scannedForCurrent,
    required this.scans,
    required this.onScan,
    this.lastScan,
    this.isBusy = false,
  });

  final ProductVariant variant;
  final int scannedForCurrent;
  final List<StockCountScanResult> scans;
  final ValueChanged<String> onScan;
  final StockCountScanResult? lastScan;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final mine = scans
        .where((scan) => scan.variantId == variant.id)
        .toList(growable: false);

    return SingleChildScrollView(
      padding: spacing.pagePadding,
      child: AdaptiveMaxWidth(
        width: AppContentWidth.detail,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyDetailCallout(
              icon: Icons.qr_code_scanner_outlined,
              title: l10n.stockCountScanShelfTitle,
              message: l10n.stockCountScanShelfBody,
            ),
            SizedBox(height: spacing.lg),
            Text(variant.fullName, style: textTheme.titleMedium),
            SizedBox(height: spacing.xs),
            Text(
              l10n.stockCountScanShelfCount(scannedForCurrent),
              style: textTheme.headlineSmall?.copyWith(
                color: colors.primaryStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: spacing.lg),
            _IdentifierField(onSubmit: onScan, enabled: !isBusy),
            if (lastScan != null && !lastScan!.created) ...[
              SizedBox(height: spacing.md),
              PointyInlineMessage.warning(
                message: l10n.stockCountScanDuplicate(lastScan!.code),
                icon: Icons.copy_all_outlined,
              ),
            ],
            SizedBox(height: spacing.lg),
            for (final scan in mine)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.qr_code_2_outlined),
                title: Text(scan.code),
                subtitle: scan.known
                    ? null
                    : Text(l10n.stockCountFindingsUnknown),
              ),
          ],
        ),
      ),
    );
  }
}

/// A text field that behaves like a scanner: submit, clear, keep the focus.
///
/// Keeping the focus matters more than it looks. A counter works down a shelf
/// with a wedge scanner in one hand; a field that loses focus after every read
/// turns a two-minute shelf into a two-minute shelf plus forty taps.
class _IdentifierField extends StatefulWidget {
  const _IdentifierField({required this.onSubmit, required this.enabled});

  final ValueChanged<String> onSubmit;
  final bool enabled;

  @override
  State<_IdentifierField> createState() => _IdentifierFieldState();
}

class _IdentifierFieldState extends State<_IdentifierField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final code = value.trim();
    _controller.clear();
    _focus.requestFocus();
    if (code.isEmpty) {
      return;
    }
    widget.onSubmit(code);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      controller: _controller,
      focusNode: _focus,
      autofocus: true,
      enabled: widget.enabled,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        labelText: l10n.stockCountScanIdentifierHint,
        prefixIcon: const Icon(Icons.qr_code_scanner_outlined),
      ),
      onSubmitted: _submit,
    );
  }
}

/// «هذا المعرّف لا يخص أي وحدة» — asked once, answered by the counter.
///
/// A code the shop has never held cannot name its own product, so the count
/// records the finding and the person holding the thing says what it is. That
/// is §6.6's *opening-identification proposal*, made actionable rather than
/// left as a line in a report.
class StockCountUnknownScanPrompt extends StatelessWidget {
  const StockCountUnknownScanPrompt({
    super.key,
    required this.code,
    required this.onPick,
    required this.onDismiss,
  });

  final String code;
  final VoidCallback onPick;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.stockCountScanUnknownTitle),
      content: Text(l10n.stockCountScanUnknownBody(code)),
      actions: [
        TextButton(
          onPressed: onDismiss,
          child: Text(l10n.stockCountScanUnknownSkip),
        ),
        FilledButton(
          onPressed: onPick,
          child: Text(l10n.stockCountScanUnknownPick),
        ),
      ],
    );
  }
}
