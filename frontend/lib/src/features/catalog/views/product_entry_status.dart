import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';

/// How many products this panel has created in a row — the running count in
/// its header while a shop enters product after product.
class ProductEntryCountPill extends StatelessWidget {
  const ProductEntryCountPill({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return PointyStatusPill(
      label: AppLocalizations.of(context)!.productEntryCreatedCount(count),
      icon: Icons.check_circle_outline,
      color: context.pointyColors.success,
    );
  }
}

/// Says once, at the moment pins first appear, what they do — no tutorial
/// beforehand, and dismissed for the rest of the session with one click.
class ProductEntryPinsHint extends StatelessWidget {
  const ProductEntryPinsHint({super.key, required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyInlineMessage(
      message: l10n.productEntryPinsHint,
      icon: Icons.push_pin_outlined,
      compact: true,
      trailing: IconButton(
        tooltip: l10n.closeButton,
        visualDensity: VisualDensity.compact,
        onPressed: onDismiss,
        icon: const Icon(Icons.close, size: 18),
      ),
    );
  }
}

/// The product the panel just created, with a way back to it.
///
/// Kept in the panel rather than a snackbar: a snackbar would queue behind the
/// next save, and a shop entering its shelves saves every few seconds. It is
/// announced to a screen reader as it changes, without taking focus.
class ProductEntryLastCreated extends StatelessWidget {
  const ProductEntryLastCreated({
    super.key,
    required this.name,
    required this.imageFailed,
    this.onEdit,
  });

  final String name;

  /// Created, but its picture did not save — said instead of the plain line.
  final bool imageFailed;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final edit = onEdit == null
        ? null
        : TextButton(
            onPressed: onEdit,
            child: Text(l10n.productEntryEditLastButton),
          );
    return Semantics(
      liveRegion: true,
      child: imageFailed
          ? PointyInlineMessage.warning(
              message: l10n.productCreatedImageAttachError,
              compact: true,
              trailing: edit,
            )
          : PointyInlineMessage.success(
              message: l10n.productEntryLastCreated(name),
              compact: true,
              trailing: edit,
            ),
    );
  }
}
