import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';

/// Opens the purchasing keyboard-shortcuts cheat sheet.
///
/// Purchasing has had a scan-then-arrow unit cycle for a while and no way to
/// discover it. A shortcut nobody can find is a shortcut nobody uses, so the
/// keys are listed the same way the POS lists its own — and the same way the
/// command palette advertises Ctrl+K.
Future<void> showPurchasingShortcutsSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final command = pointyCommandKeyLabel(context);
  return showPointyShortcutsSheet(
    context,
    title: l10n.purchasingShortcutsTitle,
    groups: [
      // An invoice row is read left to right: find the product, then its
      // quantity, cost and expiry. The groups follow that order.
      PointyShortcutGroup(l10n.purchasingShortcutsSectionSearch, [
        PointyShortcut(const ['Enter'], l10n.purchasingShortcutSearchEnter),
        PointyShortcut.either(const ['↓', '↑'], l10n.purchasingShortcutResults),
        PointyShortcut(const ['Esc'], l10n.purchasingShortcutBackToSearch),
      ]),
      PointyShortcutGroup(l10n.purchasingShortcutsSectionQuantity, [
        // The digits come first and Enter after, which the description says;
        // an Enter keycap joined to them would read as "press both".
        PointyShortcut(const ['0-9'], l10n.purchasingShortcutTypeQuantity),
        PointyShortcut(const ['Enter'], l10n.purchasingShortcutWalkNext),
        PointyShortcut.either(const [
          '+',
          '−',
        ], l10n.purchasingShortcutStepQuantity),
        PointyShortcut(const ['F6'], l10n.purchasingShortcutAcceptQuantity),
        PointyShortcut(const ['Esc'], l10n.purchasingShortcutClearEntry),
      ]),
      PointyShortcutGroup(l10n.purchasingShortcutsSectionLines, [
        PointyShortcut(const ['F5'], l10n.purchasingShortcutWalkLine),
        PointyShortcut.either(const [
          'Page ↓',
          'Page ↑',
        ], l10n.purchasingShortcutAdjacentLine),
        PointyShortcut.either(const [
          '↓',
          '↑',
        ], l10n.purchasingShortcutArrowLines),
        PointyShortcut(const ['F9'], l10n.purchasingShortcutCaptureLine),
        PointyShortcut(const ['F2'], l10n.purchasingShortcutCycleUnit),
        PointyShortcut.either(const [
          '→',
          '←',
        ], l10n.purchasingShortcutCycleUnitArrows),
        PointyShortcut(const ['F3'], l10n.purchasingShortcutOpenPricing),
        PointyShortcut(const ['F4'], l10n.purchasingShortcutDeleteLine),
      ]),
      PointyShortcutGroup(l10n.purchasingShortcutsSectionOrder, [
        PointyShortcut(const ['F1'], l10n.purchasingShortcutOpenSettings),
        PointyShortcut([command, 'Enter'], l10n.purchasingShortcutSubmit),
        PointyShortcut([
          command,
          '⇧',
          'P',
        ], l10n.purchasingShortcutOpenWorkspace),
      ]),
    ],
  );
}
