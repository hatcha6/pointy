import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'wallet_presentation.dart';

/// The ways to pay in, as tiles the owner recognises by their marks: two to a
/// row in a phone sheet or a desktop dialog, three only where a whole method
/// name still fits beside its mark. The selected one is outlined and ticked;
/// the order is the company's.
class WalletMethodPicker extends StatelessWidget {
  const WalletMethodPicker({
    super.key,
    required this.methods,
    required this.selectedKey,
    required this.onSelected,
    this.enabled = true,
  });

  final List<WalletTopUpMethod> methods;
  final String? selectedKey;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 640 ? 3 : 2;
        final gap = spacing.xs;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final method in methods)
              SizedBox(
                width: width,
                child: _MethodTile(
                  method: method,
                  selected: method.key == selectedKey,
                  onTap: enabled ? () => onSelected(method.key) : null,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({
    required this.method,
    required this.selected,
    required this.onTap,
  });

  final WalletTopUpMethod method;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(PointyRadii.chip);

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: 0.06)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? colors.primaryStrong : colors.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(spacing.sm),
            child: Row(
              children: [
                WalletMethodMark.of(method, size: 36),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        walletMethodLabel(method.key, l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        walletMethodHint(method, l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_circle,
                    size: 20,
                    color: colors.primaryStrong,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
