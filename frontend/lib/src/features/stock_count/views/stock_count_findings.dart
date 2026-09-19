import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_count_draft.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// What a scanned count found, as four named lists rather than a number.
///
/// §6.6's whole argument: for identified stock the delta is *«these three are
/// missing, and this one nobody has ever seen»*, and each of those is an
/// action somebody can take. A variance of −3 on a shelf of handsets is a
/// number nobody can act on.
class StockCountFindingsCard extends StatelessWidget {
  const StockCountFindingsCard({super.key, required this.findings});

  final StockCountScanReconciliation findings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(title: l10n.stockCountFindingsTitle),
        SizedBox(height: spacing.sm),
        Text(
          l10n.stockCountFindingsScanned(findings.scanned, findings.expected),
          style: textTheme.bodyMedium,
        ),
        SizedBox(height: spacing.md),
        _Group(
          rows: findings.missing,
          label: l10n.stockCountFindingsMissing,
          hint: l10n.stockCountFindingsMissingHint,
          icon: Icons.search_off_outlined,
          tone: PointyInlineMessageTone.error,
        ),
        _Group(
          rows: findings.unknown,
          label: l10n.stockCountFindingsUnknown,
          hint: l10n.stockCountFindingsUnknownHint,
          icon: Icons.help_outline,
          tone: PointyInlineMessageTone.warning,
        ),
        _Group(
          rows: findings.relocated,
          label: l10n.stockCountFindingsRelocated,
          hint: l10n.stockCountFindingsRelocatedHint,
          icon: Icons.swap_horiz_outlined,
          tone: PointyInlineMessageTone.warning,
        ),
        _Group(
          rows: findings.resurrected,
          label: l10n.stockCountFindingsResurrected,
          hint: l10n.stockCountFindingsResurrectedHint,
          icon: Icons.undo_outlined,
          tone: PointyInlineMessageTone.neutral,
        ),
        if (findings.lots.isNotEmpty) ...[
          SizedBox(height: spacing.md),
          PointySectionHeader(title: l10n.stockCountFindingsLots),
          for (final lot in findings.lots)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text('${lot.batchCode} · ${lot.variantName}'),
              subtitle: lot.newHere
                  ? Text(l10n.stockCountFindingsLotNew)
                  : null,
              trailing: Text(
                _signed(lot.variance),
                style: textTheme.titleMedium?.copyWith(
                  color: lot.variance == 0
                      ? context.pointyColors.mutedInk
                      : (lot.variance < 0
                            ? context.pointyColors.danger
                            : context.pointyColors.success),
                ),
              ),
            ),
        ],
      ],
    );
  }

  static String _signed(double value) {
    final text = value.toStringAsFixed(
      value.truncateToDouble() == value ? 0 : 3,
    );
    return value > 0 ? '+$text' : text;
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.rows,
    required this.label,
    required this.hint,
    required this.icon,
    required this.tone,
  });

  final List<StockCountFinding> rows;
  final String label;
  final String hint;
  final IconData icon;
  final PointyInlineMessageTone tone;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyInlineMessage(
            message: '$label · ${rows.length}\n$hint',
            icon: icon,
            tone: tone,
            compact: true,
          ),
          for (final row in rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.qr_code_2_outlined),
              title: Text(row.code),
              subtitle: Text(
                [
                  row.variantName,
                  row.detail,
                ].where((part) => part.isNotEmpty).join(' · '),
                style: textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
