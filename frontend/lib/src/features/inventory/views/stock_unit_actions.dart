import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/stock_unit.dart';
import '../../../shared/components/components.dart';

/// What a person may do to one article from its page, each behind its own
/// grant. A null callback hides its button: the page offers no door the
/// reader cannot open.
class StockUnitActionBar extends StatelessWidget {
  const StockUnitActionBar({
    super.key,
    required this.unit,
    required this.capabilities,
    required this.onIdentify,
    required this.onReprice,
    required this.onWriteOff,
    required this.onReportIncident,
    required this.onEditWarranty,
  });

  final StockUnit unit;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onIdentify;
  final VoidCallback onReprice;
  final VoidCallback onWriteOff;
  final VoidCallback onReportIncident;
  final VoidCallback onEditWarranty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // §6.8: a consigned article is never written off through this button —
    // its own rate is zero, so it would move no money and record no claim.
    final canWriteOff =
        capabilities.canWriteOffStockUnit &&
        !unit.isConsignment &&
        unit.isOnHand;
    final canReportIncident =
        capabilities.canManageConsignmentIncident && unit.isConsignment;
    // A placeholder on the shelf: the till will not sell it until it has its
    // number.
    final canIdentify =
        capabilities.canIdentifyStockUnits &&
        !unit.isIdentified &&
        unit.isOnHand;
    final canReprice = capabilities.canRepriceStockUnit && unit.isOnHand;
    final canEditWarranty = capabilities.canChangeStockUnitWarranty;

    final buttons = <Widget>[
      if (canIdentify)
        FilledButton.icon(
          key: const ValueKey('stock_unit_detail_identify'),
          onPressed: onIdentify,
          icon: const Icon(Icons.qr_code_scanner_outlined),
          label: Text(l10n.stockUnitIdentifyAction),
        ),
      if (canReprice)
        OutlinedButton.icon(
          onPressed: onReprice,
          icon: const Icon(Icons.sell_outlined),
          label: Text(l10n.stockUnitRepriceAction),
        ),
      if (canEditWarranty)
        OutlinedButton.icon(
          key: const ValueKey('stock_unit_detail_warranty'),
          onPressed: onEditWarranty,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(l10n.unitWarrantyEditAction),
        ),
      if (canWriteOff)
        OutlinedButton.icon(
          onPressed: onWriteOff,
          icon: const Icon(Icons.delete_outline),
          label: Text(l10n.stockUnitWriteOffAction),
        ),
      if (canReportIncident)
        OutlinedButton.icon(
          onPressed: onReportIncident,
          icon: const Icon(Icons.report_gmailerrorred_outlined),
          label: Text(l10n.custodyIncidentReport),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

/// The article's own asking price. Null when dismissed or unreadable.
Future<double?> showUnitRepriceDialog(BuildContext context, {double? current}) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<double>(
    context: context,
    builder: (context) => PointyNumberEntryDialog(
      title: l10n.stockUnitRepriceAction,
      fieldLabel: l10n.stockUnitOwnPrice,
      icon: Icons.sell_outlined,
      initialValue: current?.toStringAsFixed(2) ?? '',
      isValid: (value) => value >= 0,
      confirmLabel: l10n.saveButton,
    ),
  );
}

/// Why the article is leaving. Stock leaves, so the reason is part of the
/// record rather than a courtesy.
Future<String?> showUnitWriteOffDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final reason = await showDialog<String>(
    context: context,
    builder: (context) => PointyTextEntryDialog(
      title: l10n.stockUnitWriteOffAction,
      fieldLabel: l10n.stockUnitWriteOffReason,
      confirmLabel: l10n.stockUnitWriteOffAction,
      icon: Icons.delete_outline,
      isDestructive: true,
    ),
  );
  final trimmed = reason?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
