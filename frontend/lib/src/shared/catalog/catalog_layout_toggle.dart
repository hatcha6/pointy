import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';
import 'catalog_layout_controller.dart';

/// The two-way switch between a catalog's picture cards and its table.
///
/// Icons only, so it fits beside the catalog title on the narrowest till; each
/// half names itself in a tooltip.
class CatalogLayoutToggle extends StatelessWidget {
  const CatalogLayoutToggle({
    super.key,
    required this.layout,
    required this.onChanged,
  });

  final CatalogLayout layout;
  final ValueChanged<CatalogLayout> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return Semantics(
      container: true,
      label: l10n.catalogLayoutToggleLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(PointyRadii.chip),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _LayoutSegment(
                key: const ValueKey('catalog_layout_grid'),
                icon: Icons.grid_view_rounded,
                tooltip: l10n.catalogLayoutGridTooltip,
                selected: layout == CatalogLayout.grid,
                onTap: () => onChanged(CatalogLayout.grid),
              ),
              const SizedBox(width: 2),
              _LayoutSegment(
                key: const ValueKey('catalog_layout_list'),
                icon: Icons.view_list_rounded,
                tooltip: l10n.catalogLayoutListTooltip,
                selected: layout == CatalogLayout.list,
                onTap: () => onChanged(CatalogLayout.list),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LayoutSegment extends StatelessWidget {
  const _LayoutSegment({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final radius = BorderRadius.circular(PointyRadii.chip - 3);

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? colors.primaryContainer : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            overlayColor: PointyComponentStyles.inkOverlay(colors.ink),
            onTap: onTap,
            child: SizedBox(
              width: 36,
              height: 30,
              child: Icon(
                icon,
                size: 20,
                color: selected ? colors.primaryDark : colors.mutedInk,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
