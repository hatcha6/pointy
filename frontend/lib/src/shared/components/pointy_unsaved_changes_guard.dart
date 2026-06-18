import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

/// Wraps an editable surface so that an attempt to leave (system/predictive
/// back, or a dismissible barrier tap) while there are unsaved edits prompts a
/// "discard changes?" dialog instead of silently losing work.
///
/// [isDirty] is evaluated *fresh* on every back/dismiss attempt, so it stays
/// correct even for surfaces whose edits (text controllers) don't trigger a
/// rebuild on every keystroke. An explicit `Navigator.pop()` from the surface's
/// own save handler is NOT intercepted (it bypasses [PopScope]), so saving
/// still closes normally.
///
/// Note: mobile drag-to-dismiss on a modal sheet can bypass this on some
/// platforms — pass `enableDrag: false` to the sheet where that matters.
class PointyUnsavedChangesGuard extends StatelessWidget {
  const PointyUnsavedChangesGuard({
    super.key,
    required this.isDirty,
    required this.child,
    this.onDiscard,
  });

  final bool Function() isDirty;
  final Widget child;

  /// Invoked after the user confirms discarding, just before the pop completes.
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Always intercept so [isDirty] is consulted live rather than at build
      // time; a clean surface pops immediately inside the callback.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        final navigator = Navigator.of(context);
        if (!isDirty()) {
          navigator.pop(result);
          return;
        }
        final confirmed = await confirmDiscardUnsavedChanges(context);
        if (confirmed == true) {
          onDiscard?.call();
          navigator.pop(result);
        }
      },
      child: child,
    );
  }
}

/// Shows the shared "discard unsaved changes?" dialog. Returns true when the
/// user chooses to discard. Reusable outside the guard (e.g. an explicit close
/// button) so every surface uses the same copy.
Future<bool?> confirmDiscardUnsavedChanges(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        icon: Icon(Icons.warning_amber_outlined, color: colors.danger),
        title: Text(l10n.unsavedChangesTitle),
        content: Text(l10n.unsavedChangesMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.keepEditingButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.surface,
            ),
            child: Text(l10n.discardChangesButton),
          ),
        ],
      ),
    ),
  );
}
