import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/design/design.dart';

/// The pin beside a carried field: whether its value goes on to the next
/// product, and whether what it shows now is still the previous product's.
///
/// Absent until a run has begun — before the first «إنشاء وإضافة آخر» there is
/// no previous product to keep anything from.
class FieldPin {
  const FieldPin({
    required this.pinned,
    required this.kept,
    required this.onToggle,
    this.keptLabel,
  });

  /// The value carries over to the next product.
  final bool pinned;

  /// The field still shows the previous product's value, untouched.
  final bool kept;

  /// Null while there is nothing to pin for yet: a «منتج مشابه» not created
  /// marks what it copied, and shows its pins from the first «إضافة آخر».
  final VoidCallback? onToggle;

  /// Where a [kept] value came from, when that is not the previous product —
  /// the one a «منتج مشابه» copies.
  final String? keptLabel;

  /// The tint of a field that still shows the previous product's value, so a
  /// carried value never passes for one typed in for this product.
  Color? fillColor(BuildContext context) =>
      kept ? context.pointyColors.primaryContainer : null;
}

/// A form field with its pin beside it and, while it still shows the previous
/// product's value, a line under it saying so.
///
/// Laid out the same with or without a pin, so the field keeps its state —
/// and focus — at the moment the pins appear.
class PinnableField extends StatelessWidget {
  const PinnableField({
    super.key,
    required this.child,
    this.pin,
    this.focusScope,
    this.showKeptLabel = true,
  });

  final Widget child;
  final FieldPin? pin;

  /// Reports whether focus is anywhere inside this field — how the pin
  /// shortcut knows which field it is aimed at. Never takes focus itself.
  final FocusNode? focusScope;

  /// Off while the field carries a warning of its own about the same value.
  final bool showKeptLabel;

  @override
  Widget build(BuildContext context) {
    final pin = this.pin;
    final colors = context.pointyColors;
    return Focus(
      focusNode: focusScope,
      canRequestFocus: false,
      skipTraversal: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: child),
              if (pin != null && pin.onToggle != null) ...[
                const SizedBox(width: 4),
                FieldPinButton(pin: pin),
              ],
            ],
          ),
          if (pin != null && pin.kept && showKeptLabel)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 12, top: 4),
              child: Row(
                children: [
                  Icon(Icons.push_pin, size: 14, color: colors.primaryStrong),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      pin.keptLabel ??
                          AppLocalizations.of(context)!.productFieldKeptLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.primaryStrong,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The pin itself.
///
/// Kept out of the focus order on purpose. Tab must not stop on a pin beside
/// every field, and a pin holding focus when a scanner's Enter arrives would be
/// pressed by it — a scan the listener consumed still reaches whatever has
/// focus. F7 pins from the keyboard instead.
class FieldPinButton extends StatelessWidget {
  const FieldPinButton({super.key, required this.pin});

  final FieldPin pin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    // Clicking it also leaves the field being typed in focused: a pin counts
    // as part of the form's text fields rather than a tap outside them.
    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IconButton(
            tooltip: pin.pinned
                ? l10n.productFieldUnpinTooltip
                : l10n.productFieldPinTooltip,
            isSelected: pin.pinned,
            onPressed: pin.onToggle,
            icon: Icon(Icons.push_pin_outlined, color: colors.mutedInk),
            selectedIcon: Icon(Icons.push_pin, color: colors.primaryStrong),
            style: IconButton.styleFrom(
              backgroundColor: pin.pinned ? colors.primaryContainer : null,
            ),
          ),
        ),
      ),
    );
  }
}
