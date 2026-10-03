import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/barcode/camera_wedge/camera_wedge_scope.dart';
import '../../../shared/components/components.dart';

/// Opens the POS keyboard-shortcuts cheat sheet: a labeled, keycap-styled list
/// of every till shortcut, so cashiers who don't use shortcuts can still see
/// and recognise them (mirroring how the command palette advertises ⌘/Ctrl K).
Future<void> showPosShortcutsSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final command = pointyCommandKeyLabel(context);
  return showPointyShortcutsSheet(
    context,
    title: l10n.posShortcutsTitle,
    subtitle: l10n.posShortcutsSubtitle,
    groups: [
      PointyShortcutGroup(l10n.posShortcutsSectionInvoices, [
        PointyShortcut(const ['F1'], l10n.posShortcutNewInvoice),
        PointyShortcut.either(const [
          'Page ↓',
          'Page ↑',
        ], l10n.posShortcutCycleInvoices),
      ]),
      PointyShortcutGroup(l10n.posShortcutsSectionItems, [
        PointyShortcut(const ['F2'], l10n.posShortcutCycleUnit),
        PointyShortcut(const ['F4'], l10n.posShortcutDeleteLine),
        PointyShortcut(const ['F9'], l10n.posShortcutToggleCost),
        // Only on a till with a counter camera running: F8 does nothing
        // anywhere else (camera_wedge_preview_panel.dart).
        if (CameraWedgeScope.controllerOf(context) != null)
          PointyShortcut(const ['F8'], l10n.posShortcutCameraPreview),
      ]),
      PointyShortcutGroup(l10n.posShortcutsSectionCheckout, [
        PointyShortcut([command, 'Enter'], l10n.posShortcutCheckout),
      ]),
      // The payment keys are modifier-prefixed so a bare digit always lands in
      // the amount field — which makes them worth spelling out here, since a
      // cashier will not discover them by accident.
      PointyShortcutGroup(l10n.posShortcutsSectionPayment, [
        PointyShortcut([command, '1'], l10n.posShortcutPayCash),
        PointyShortcut([command, '2'], l10n.posShortcutPayCard),
        PointyShortcut([command, '3'], l10n.posShortcutPayTransfer),
        PointyShortcut(const ['Enter'], l10n.posShortcutConfirmPayment),
        PointyShortcut(const ['Esc'], l10n.posShortcutCancelPayment),
      ]),
    ],
  );
}
