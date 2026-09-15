import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/sale_order.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/payment_labels.dart';
import '../../../../shared/tutor/anchors.dart';
import '../../../../shared/tutor/tutor_target.dart';

/// Single-select control for the active tender's payment method. Splitting a
/// payment is a separate, explicit action (the full-width "add payment" button
/// under the tender line), so it is deliberately not a fourth segment here.
class PaymentMethodSegmentedControl extends StatelessWidget {
  const PaymentMethodSegmentedControl({
    super.key,
    required this.label,
    required this.enabledMethods,
    required this.selectedMethod,
    required this.onSelected,
  });

  final String label;
  final List<PaymentMethod> enabledMethods;
  final PaymentMethod? selectedMethod;
  final ValueChanged<PaymentMethod> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (enabledMethods.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = context.pointyColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<PaymentMethod>(
            showSelectedIcon: false,
            // Keep selection in the brand's teal language (the theme default is
            // the amber secondaryContainer, which clashes with the rest of the
            // checkout's teal selected states).
            style: SegmentedButton.styleFrom(
              backgroundColor: colors.surface,
              foregroundColor: colors.ink,
              selectedBackgroundColor: Color.alphaBlend(
                colors.primaryStrong.withValues(alpha: 0.14),
                colors.surface,
              ),
              selectedForegroundColor: colors.primaryDark,
              side: BorderSide(color: colors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PointyRadii.chip),
              ),
            ),
            segments: [
              for (final method in enabledMethods)
                ButtonSegment(
                  value: method,
                  icon: Icon(paymentMethodIcon(method)),
                  label: TutorTarget(
                    anchor: TutorAnchor.paymentMethodSegment,
                    id: method.apiValue,
                    child: Text(
                      paymentMethodLabel(l10n, method),
                      key: ValueKey('payment_method_${method.apiValue}'),
                    ),
                  ),
                ),
            ],
            selected: {?selectedMethod},
            onSelectionChanged: (selected) {
              if (selected.isEmpty) {
                return;
              }
              onSelected(selected.first);
            },
          ),
        ),
      ],
    );
  }
}
