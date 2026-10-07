import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/sale_order.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/payment_labels.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../../../shared/tutor/anchors.dart';
import '../../../../shared/tutor/tutor_target.dart';

/// Single-select control for the active tender's payment method. Splitting a
/// payment is a separate, explicit action (the full-width "add payment" button
/// under the tender line), so it is deliberately not a fourth segment here.
///
/// One large tile per method, each in the method's own colour
/// ([paymentMethodColor]), and the chosen one filled solid. It used to be a
/// grey segmented button with a faint tint on the selection, and cashiers
/// confirmed card and transfer sales on the preselected cash without ever
/// seeing it: the choice has to be impossible to miss at a glance.
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
    if (enabledMethods.isEmpty) {
      return const SizedBox.shrink();
    }
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        SizedBox(height: spacing.sm),
        Row(
          children: [
            for (final (index, method) in enabledMethods.indexed) ...[
              if (index > 0) SizedBox(width: spacing.sm),
              Expanded(
                child: _PaymentMethodTile(
                  method: method,
                  selected: method == selectedMethod,
                  onTap: () => onSelected(method),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _PaymentMethodTile extends StatelessWidget {
  const _PaymentMethodTile({
    required this.method,
    required this.selected,
    required this.onTap,
  });

  final PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final hue = paymentMethodColor(colors, method);
    final foreground = selected ? onPaymentMethodColor(hue) : hue;

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        key: ValueKey('payment_method_tile_${method.apiValue}'),
        color: selected ? hue : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PointyRadii.chip),
          side: BorderSide(
            color: selected ? hue : hue.withValues(alpha: 0.55),
            width: selected ? 2 : 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    selected ? Icons.check_circle : paymentMethodIcon(method),
                    color: foreground,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: TutorTarget(
                      anchor: TutorAnchor.paymentMethodSegment,
                      id: method.apiValue,
                      child: Text(
                        paymentMethodLabel(l10n, method),
                        key: ValueKey('payment_method_${method.apiValue}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w700,
                          color: selected ? foreground : colors.ink,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
