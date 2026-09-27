import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';

/// Warns that cart lines sell below cost, before payment or after checkout
/// refused the sale. [canSellAtLoss] offers to go on anyway.
///
/// The lines are always named. They are priced only when [showAmounts] and the
/// server sent the figures: the loss is the cost less a total the cashier
/// typed, so a cashier who may not see cost is told which line, not by how
/// much — and, refused, is sent to a manager rather than left to guess at a
/// price that clears the guard.
Future<bool?> showLossWarningDialog(
  BuildContext context, {
  required List<SaleLossLine> lossLines,
  required bool canSellAtLoss,
  required bool showAmounts,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => LossWarningDialog(
      lossLines: lossLines,
      canSellAtLoss: canSellAtLoss,
      showAmounts: showAmounts,
    ),
  );
}

class LossWarningDialog extends StatelessWidget {
  const LossWarningDialog({
    super.key,
    required this.lossLines,
    required this.canSellAtLoss,
    required this.showAmounts,
  });

  final List<SaleLossLine> lossLines;
  final bool canSellAtLoss;
  final bool showAmounts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_outlined),
      title: Text(l10n.lossSaleWarningTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_message(l10n)),
            const SizedBox(height: 12),
            for (final line in lossLines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(_lineText(l10n, line)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            canSellAtLoss ? l10n.cancelButton : l10n.reviewCartButton,
          ),
        ),
        if (canSellAtLoss)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.continueSaleButton),
          ),
      ],
    );
  }

  String _message(AppLocalizations l10n) {
    if (canSellAtLoss) {
      return l10n.lossSaleWarningMessage;
    }
    return showAmounts
        ? l10n.lossSaleBlockedMessage
        : l10n.lossSaleBlockedAskManagerMessage;
  }

  String _lineText(AppLocalizations l10n, SaleLossLine line) {
    final amount = showAmounts ? line.lossAmount : null;
    return amount == null
        ? l10n.lossSaleBelowCostLine(line.productName)
        : l10n.lossSaleLine(line.productName, formatMoney(amount));
  }
}
