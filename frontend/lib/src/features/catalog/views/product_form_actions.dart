import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';

/// The new-product form's buttons: back (on the variants step), the primary
/// action, and — where the caller offers it — «إنشاء وإضافة آخر», which saves
/// and starts the next product without closing the panel.
///
/// On a keyboard machine each button carries its shortcut underneath, so the
/// keys are learnt from the buttons they stand for.
class ProductFormActions extends StatelessWidget {
  const ProductFormActions({
    super.key,
    required this.isSaving,
    required this.isFinalStep,
    required this.primaryFocusNode,
    required this.onPrimary,
    required this.showShortcutHints,
    this.savingAddAnother = false,
    this.onBack,
    this.addAnotherFocusNode,
    this.onAddAnother,
  });

  final bool isSaving;

  /// False on the first page of a product that generates variants, where the
  /// primary button moves on to them instead of creating.
  final bool isFinalStep;
  final FocusNode primaryFocusNode;
  final VoidCallback onPrimary;
  final bool showShortcutHints;

  /// The save in flight came from «إنشاء وإضافة آخر», so its button spins.
  final bool savingAddAnother;
  final VoidCallback? onBack;
  final FocusNode? addAnotherFocusNode;

  /// Null where the caller does not offer adding another (a purchase order
  /// adds each created product to itself and closes).
  final VoidCallback? onAddAnother;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final command = pointyCommandKeyLabel(context);
    final showsAddAnother = onAddAnother != null && isFinalStep;
    const spinner = SizedBox.square(
      dimension: 18,
      child: PointySpinner(strokeWidth: 2),
    );

    Widget withHint(Widget button, List<String> keys) {
      if (!showShortcutHints) {
        return button;
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          button,
          const SizedBox(height: 4),
          Center(child: PointyKeyCombo(keys: keys, dense: true)),
        ],
      );
    }

    final primary = TutorTarget(
      anchor: TutorAnchor.productFormPrimaryButton,
      child: FilledButton.icon(
        focusNode: primaryFocusNode,
        onPressed: isSaving ? null : onPrimary,
        icon: isSaving && !savingAddAnother
            ? spinner
            : Icon(isFinalStep ? Icons.add : Icons.arrow_forward),
        label: Text(
          isSaving && !savingAddAnother
              ? l10n.creatingProductButton
              : isFinalStep
              ? l10n.createProductButton
              : l10n.nextButton,
        ),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onBack != null) ...[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: isSaving ? null : onBack,
              icon: const Icon(Icons.arrow_back),
              label: Text(l10n.backButton),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(child: withHint(primary, [command, 'Enter'])),
        if (showsAddAnother) ...[
          const SizedBox(width: 12),
          Expanded(
            child: withHint(
              OutlinedButton.icon(
                key: const ValueKey('product_form_add_another_button'),
                focusNode: addAnotherFocusNode,
                onPressed: isSaving ? null : onAddAnother,
                icon: isSaving && savingAddAnother
                    ? spinner
                    : const Icon(Icons.playlist_add),
                label: Text(
                  isSaving && savingAddAnother
                      ? l10n.creatingProductButton
                      : l10n.createAndAddAnotherButton,
                ),
              ),
              [command, 'Shift', 'Enter'],
            ),
          ),
        ],
      ],
    );
  }
}
