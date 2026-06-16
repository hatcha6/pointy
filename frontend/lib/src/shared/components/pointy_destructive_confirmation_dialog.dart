import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyDestructiveConfirmationDialog extends StatelessWidget {
  const PointyDestructiveConfirmationDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.icon = Icons.warning_amber_outlined,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        icon: Icon(icon, color: colors.danger),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.surface,
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
}
