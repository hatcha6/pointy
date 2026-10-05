import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/formatters.dart';

/// How a consignor is paid: cash from the open till, or a bank transfer.
///
/// Shared by the payables screen and the consignor statement, which both end
/// in the same act. Returns `'cash'`, `'bank'`, or null when dismissed.
Future<String?> showConsignmentPayoutMethodSheet(
  BuildContext context, {
  required double total,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => _PayoutMethodSheet(total: total),
  );
}

class _PayoutMethodSheet extends StatelessWidget {
  const _PayoutMethodSheet({required this.total});

  final double total;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.consignmentPayoutMethodTitle(formatMoney(total)),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.payments_outlined),
              title: Text(l10n.consignmentPayoutCash),
              subtitle: Text(l10n.consignmentPayoutCashHint),
              onTap: () => Navigator.of(context).pop('cash'),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_outlined),
              title: Text(l10n.consignmentPayoutBank),
              onTap: () => Navigator.of(context).pop('bank'),
            ),
          ],
        ),
      ),
    );
  }
}
