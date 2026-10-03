import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';

/// The new-product form's keyboard cheat sheet.
///
/// [offersAddAnother] is false where the form saves and closes only (inside a
/// purchase order), so the keys for a run of products are left off.
Future<void> showProductFormShortcutsSheet(
  BuildContext context, {
  required bool offersAddAnother,
}) {
  final l10n = AppLocalizations.of(context)!;
  final command = pointyCommandKeyLabel(context);
  return showPointyShortcutsSheet(
    context,
    title: l10n.productFormShortcutsTitle,
    groups: [
      PointyShortcutGroup(l10n.productFormShortcutsSectionSave, [
        PointyShortcut(const ['Enter'], l10n.productFormShortcutNextField),
        PointyShortcut([command, 'Enter'], l10n.productFormShortcutCreate),
        if (offersAddAnother)
          PointyShortcut([
            command,
            'Shift',
            'Enter',
          ], l10n.productFormShortcutCreateAnother),
        PointyShortcut(const ['Esc'], l10n.productFormShortcutClose),
      ]),
      if (offersAddAnother)
        PointyShortcutGroup(l10n.productFormShortcutsSectionRun, [
          PointyShortcut(const ['F7'], l10n.productFormShortcutPinField),
          PointyShortcut([command, 'N'], l10n.productFormShortcutNewProduct),
        ]),
    ],
    note: l10n.productFormShortcutsScanNote,
  );
}
