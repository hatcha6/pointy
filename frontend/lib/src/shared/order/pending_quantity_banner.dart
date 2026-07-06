import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';

/// Preview of a quantity being typed for the selected line — shown while the
/// keyboard entry accumulates, applied on Enter. Shared by the POS cart and
/// the purchasing draft so both feel identical.
class PendingQuantityBanner extends StatelessWidget {
  const PendingQuantityBanner({
    super.key,
    required this.quantity,
    required this.productName,
  });

  final String quantity;
  final String productName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Container(
      width: double.infinity,
      margin: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.primaryStrong),
      ),
      child: Row(
        children: [
          Icon(Icons.tag_outlined, size: 18, color: colors.primaryStrong),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.cartQuantityPendingLabel(quantity, productName),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.primaryDark,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.cartQuantityPendingHint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.primaryStrong,
            ),
          ),
        ],
      ),
    );
  }
}
