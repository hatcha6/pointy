import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../responsive/responsive.dart';
import '../unit_options.dart';

/// The unit an F2 or arrow press moves an order line to — the same cycle on
/// the POS and on a purchase order, so a cashier moved onto receiving does
/// not relearn it.
///
/// Arrow Up/Right is next, Down/Left previous, and F2 ([key] null) next;
/// it wraps. Null when there is nothing to cycle through.
UnitOption? cycledUnitOption(
  List<UnitOption> options,
  String currentCode, [
  LogicalKeyboardKey? key,
]) {
  if (options.length < 2) {
    return null;
  }
  final code = currentCode.isEmpty ? options.first.code : currentCode;
  var index = options.indexWhere((option) => option.code == code);
  if (index == -1) {
    index = 0;
  }
  final forward =
      key == null ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowRight;
  return options[(index + (forward ? 1 : -1) + options.length) %
      options.length];
}

/// Says a line was removed, with an Undo — a delete key that misfires on an
/// order somebody is halfway through must be one tap to recover.
void showLineRemovedUndo(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
}) {
  final l10n = AppLocalizations.of(context)!;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: l10n.undoButton, onPressed: onUndo),
      ),
    );
}

/// Hands the keyboard back to a catalog search box once the current frame is
/// done — the request usually fires mid-rebuild (a line just landed) — unless
/// a sheet or dialog is up, or on a phone, where it would steal a caret or pop
/// the soft keyboard unbidden. Shared by the POS and the purchase order.
///
/// It also asks for that frame. A key press that changes nothing on screen
/// (Esc out of a result, the last Enter of a line) schedules none, and the
/// focus used to wait there until the mouse moved.
void focusSearchAfterFrame(BuildContext context, FocusNode searchFocusNode) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      return;
    }
    if (AppBreakpoints.of(context).index < AppBreakpoint.tablet.index) {
      return;
    }
    searchFocusNode.requestFocus();
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}
