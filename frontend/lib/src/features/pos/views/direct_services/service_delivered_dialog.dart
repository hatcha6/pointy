import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/integration_card.dart';
import '../../../../data/models/provider_receipt_fields.dart';
import '../../../../shared/components/pointy_fitted_token.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import 'service_test_mode_banner.dart';

/// Tells the cashier what a sale's airtime and bill lines did, once the
/// provider has answered: the number, the network, what arrived and its
/// reference — and, for a bill, the token the customer must be handed, large
/// and ready to copy.
///
/// The rows are the server's own words (`receipt.rows`), the same ones the
/// receipt prints, so what the cashier sees is what the customer is given.
///
/// [testMode] says the sale was made while the relay was buying from its test
/// supplier — the till knows it from the lines it sold — and the dialog then
/// says «عملية تجريبية»; an answer that says so itself does the same.
Future<void> showServiceDeliveredDialog(
  BuildContext context,
  List<IntegrationChargeResult> delivered, {
  bool testMode = false,
}) {
  final hasToken = delivered.any(
    (row) => (row.receipt['pin'] ?? '').trim().isNotEmpty,
  );
  return showDialog<void>(
    context: context,
    // A token is the thing that was bought: it is not dismissed by a stray tap.
    barrierDismissible: !hasToken,
    builder: (dialogContext) =>
        ServiceDeliveredDialog(results: delivered, testMode: testMode),
  );
}

class ServiceDeliveredDialog extends StatelessWidget {
  const ServiceDeliveredDialog({
    super.key,
    required this.results,
    this.testMode = false,
  });

  final List<IntegrationChargeResult> results;

  /// The sale was made in test mode (or any answer in it says it was).
  final bool testMode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final title = results.every((row) => row.isBill)
        ? l10n.posServicesSuccessBillTitle
        : results.every((row) => row.isAirtime)
        ? l10n.posServicesSuccessAirtimeTitle
        : l10n.posServicesSuccessMixedTitle;
    return AlertDialog(
      key: const ValueKey('service_delivered_dialog'),
      icon: Icon(Icons.check_circle_rounded, color: colors.success, size: 44),
      title: Text(title, textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (testMode || results.any((row) => row.testMode)) ...[
                const Center(child: ServiceTestModeMark()),
                const SizedBox(height: 12),
              ],
              for (final (index, row) in results.indexed) ...[
                if (index > 0) const Divider(height: 24),
                _DeliveredSection(result: row),
              ],
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        FilledButton(
          key: const ValueKey('service_delivered_done'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.posServicesSuccessDone),
        ),
      ],
    );
  }
}

class _DeliveredSection extends StatelessWidget {
  const _DeliveredSection({required this.result});

  final IntegrationChargeResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final receipt = result.receipt;
    var rows = providerReceiptRows(receipt);
    if (rows.isEmpty) {
      // A server that sent no ready-made rows still said what it did.
      rows = [
        if (result.subscriberRef.isNotEmpty)
          [l10n.posServicesSuccessNumber, result.subscriberRef],
        if (result.optionLabel.isNotEmpty)
          [l10n.posServicesSuccessOperation, result.optionLabel],
        if (result.providerReference.isNotEmpty)
          [l10n.posServicesSuccessReference, result.providerReference],
      ];
    }
    final token = (receipt['pin'] ?? '').trim();
    final tokenLabel = (receipt['pin_label'] ?? '').trim().isNotEmpty
        ? receipt['pin_label']!.trim()
        : l10n.posServicesSuccessToken;
    final notice = (receipt['notice'] ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows) _FactRow(row: row),
        if (token.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  tokenLabel,
                  textAlign: TextAlign.center,
                  style: textTheme.labelLarge?.copyWith(color: colors.mutedInk),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('service_delivered_copy'),
                tooltip: l10n.posServicesSuccessCopy,
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: token));
                  if (context.mounted) {
                    ScaffoldMessenger.maybeOf(context)
                      ?..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(content: Text(l10n.posServicesSuccessCopied)),
                      );
                  }
                },
                icon: const Icon(Icons.copy_rounded),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // The whole token on one line, however long it is and however wide
          // the dialog: a token split over two lines is read wrongly into a
          // meter.
          Container(
            key: const ValueKey('service_delivered_token_box'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(PointyRadii.input),
              border: Border.all(
                color: colors.primaryStrong.withValues(alpha: 0.35),
              ),
            ),
            child: Center(
              child: PointyFittedToken(
                textKey: const ValueKey('service_delivered_token'),
                code: token,
                style: PointyTypography.numeric(
                  (textTheme.headlineSmall ?? const TextStyle()).copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: colors.primaryDark,
                  ),
                ),
              ),
            ),
          ),
          // One line of advice about the token, not two: the server's own when
          // its slip has one — it says the same, in its words, and the test
          // supplier's says what is not real — else ours.
          if (notice.isEmpty) ...[
            const SizedBox(height: 6),
            Text(
              l10n.posServicesSuccessTokenHint,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ],
        if (notice.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            notice,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ],
    );
  }
}

/// One `[label, value]` line, the value held left to right when it is a
/// number or a Latin name.
class _FactRow extends StatelessWidget {
  const _FactRow({required this.row});

  final List<String> row;

  static final RegExp _latin = RegExp(r'^[\x20-\x7E]+$');

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final label = row.length > 1 ? row.first : '';
    final value = row.length > 1 ? row.sublist(1).join(' ') : row.first;
    final ltr = _latin.hasMatch(value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            ),
          Expanded(
            child: Text(
              ltr ? ltrIsolated(value) : value,
              textAlign: label.isEmpty ? TextAlign.center : TextAlign.start,
              style: PointyTypography.numeric(
                (textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
