import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/sale_order.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/payment_labels.dart';

class PaymentMethodSegmentedControl extends StatelessWidget {
  const PaymentMethodSegmentedControl({
    super.key,
    required this.label,
    required this.enabledMethods,
    required this.selectedMethod,
    required this.splitTenderEnabled,
    required this.splitTenderSelected,
    required this.onSelected,
    required this.onSplitTenderSelected,
  });

  final String label;
  final List<PaymentMethod> enabledMethods;
  final PaymentMethod? selectedMethod;
  final bool splitTenderEnabled;
  final bool splitTenderSelected;
  final ValueChanged<PaymentMethod> onSelected;
  final VoidCallback onSplitTenderSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (enabledMethods.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = context.pointyColors;
    final selectedSegment = splitTenderSelected
        ? _PaymentMethodSegment.splitTender
        : _PaymentMethodSegment.fromMethod(selectedMethod);

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
        SegmentedButton<_PaymentMethodSegment>(
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
                value: _PaymentMethodSegment.fromMethod(method)!,
                icon: Icon(paymentMethodIcon(method)),
                label: Text(
                  paymentMethodLabel(l10n, method),
                  key: ValueKey('payment_method_${method.apiValue}'),
                ),
              ),
            if (splitTenderEnabled)
              ButtonSegment(
                value: _PaymentMethodSegment.splitTender,
                icon: const Icon(Icons.call_split),
                label: Text(
                  l10n.paymentMethodSplitTender,
                  key: const ValueKey('payment_method_split_tender'),
                ),
              ),
          ],
          selected: {?selectedSegment},
          onSelectionChanged: (selected) {
            if (selected.isEmpty) {
              return;
            }
            final segment = selected.first;
            if (segment == _PaymentMethodSegment.splitTender) {
              onSplitTenderSelected();
              return;
            }
            final method = segment.method;
            if (method != null) {
              onSelected(method);
            }
          },
        ),
      ],
    );
  }
}

enum _PaymentMethodSegment {
  cash(PaymentMethod.cash),
  card(PaymentMethod.card),
  transfer(PaymentMethod.transfer),
  splitTender(null);

  const _PaymentMethodSegment(this.method);

  final PaymentMethod? method;

  static _PaymentMethodSegment? fromMethod(PaymentMethod? method) {
    return switch (method) {
      PaymentMethod.cash => _PaymentMethodSegment.cash,
      PaymentMethod.card => _PaymentMethodSegment.card,
      PaymentMethod.transfer => _PaymentMethodSegment.transfer,
      null => null,
    };
  }
}
