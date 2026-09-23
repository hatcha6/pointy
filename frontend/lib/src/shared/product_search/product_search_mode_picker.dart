import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/product_query.dart';
import '../design/design.dart';
import '../responsive/responsive.dart';

typedef ProductSearchModeLabel = ({
  IconData icon,
  String label,
  String description,
});

ProductSearchModeLabel productSearchModeLabel(
  ProductSearchMode mode,
  AppLocalizations l10n,
) {
  return switch (mode) {
    ProductSearchMode.all => (
      icon: Icons.manage_search,
      label: l10n.productSearchModeAll,
      description: l10n.productSearchModeAllDescription,
    ),
    ProductSearchMode.code => (
      icon: Icons.barcode_reader,
      label: l10n.productSearchModeCode,
      description: l10n.productSearchModeCodeDescription,
    ),
    ProductSearchMode.name => (
      icon: Icons.sort_by_alpha,
      label: l10n.productSearchModeName,
      description: l10n.productSearchModeNameDescription,
    ),
  };
}

/// The dropdown at the end of a product search that says what it reads: codes,
/// names, or both.
///
/// Only a machine whose device settings turned it on shows one (see
/// [ProductSearchModeController]); everywhere else the field is the plain
/// search it always was.
///
/// The chip does not take focus when it is clicked, so once the menu closes
/// focus returns to the search field underneath and the cashier carries on
/// typing — or scanning — without reaching for it.
class ProductSearchModePicker extends StatelessWidget {
  const ProductSearchModePicker({
    super.key,
    required this.mode,
    required this.onChanged,
    this.compact = false,
    this.enabled = true,
  });

  final ProductSearchMode mode;
  final ValueChanged<ProductSearchMode> onChanged;

  /// The icon without its label, for a field too narrow to spare the words.
  /// The tooltip and the menu still name every mode.
  final bool compact;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final selected = productSearchModeLabel(mode, l10n);
    final color = enabled ? colors.primaryStrong : colors.mutedInk;
    final radius = BorderRadius.circular(6);

    return Padding(
      padding: EdgeInsetsDirectional.only(end: spacing.xs),
      child: PopupMenuButton<ProductSearchMode>(
        key: const ValueKey('product_search_mode_picker'),
        tooltip: l10n.productSearchModeTooltip(selected.label),
        enabled: enabled,
        initialValue: mode,
        position: PopupMenuPosition.under,
        borderRadius: radius,
        onSelected: (value) {
          if (value != mode) {
            onChanged(value);
          }
        },
        itemBuilder: (context) => [
          for (final option in ProductSearchMode.values)
            PopupMenuItem<ProductSearchMode>(
              key: ValueKey('product_search_mode_${option.name}'),
              value: option,
              child: _ModeOption(
                label: productSearchModeLabel(option, l10n),
                selected: option == mode,
              ),
            ),
        ],
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.35),
            borderRadius: radius,
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: spacing.sm,
              end: spacing.xs,
              top: spacing.xs,
              bottom: spacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(selected.icon, size: 18, color: color),
                if (!compact) ...[
                  SizedBox(width: spacing.xs),
                  Text(
                    selected.label,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: color),
                  ),
                ],
                Icon(Icons.arrow_drop_down, size: 20, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({required this.label, required this.selected});

  final ProductSearchModeLabel label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Icon(
          label.icon,
          size: 20,
          color: selected ? colors.primaryStrong : colors.mutedInk,
        ),
        SizedBox(width: spacing.sm),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.label,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
              Text(
                label.description,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
        ),
        if (selected) ...[
          SizedBox(width: spacing.sm),
          Icon(Icons.check, size: 18, color: colors.primaryStrong),
        ],
      ],
    );
  }
}
