import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/sale_order.dart';
import '../../../../shared/decimal_text_input_formatter.dart';
import '../../../../shared/payment_labels.dart';
import '../../../../shared/responsive/responsive.dart';

class TenderLineEditor extends StatelessWidget {
  const TenderLineEditor({
    super.key,
    required this.index,
    required this.title,
    required this.amountLabel,
    required this.methodLabel,
    required this.removeTooltip,
    required this.amountController,
    required this.method,
    required this.enabledMethods,
    required this.canRemove,
    required this.isSelected,
    required this.onSelected,
    required this.onAmountChanged,
    required this.onMethodChanged,
    required this.onRemove,
  });

  final int index;
  final String title;
  final String amountLabel;
  final String methodLabel;
  final String removeTooltip;
  final TextEditingController amountController;
  final PaymentMethod method;
  final List<PaymentMethod> enabledMethods;
  final bool canRemove;
  final bool isSelected;
  final VoidCallback onSelected;
  final VoidCallback onAmountChanged;
  final ValueChanged<PaymentMethod> onMethodChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onSelected,
        child: Padding(
          padding: EdgeInsetsDirectional.all(spacing.sm),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final amountField = TextField(
                key: ValueKey('payment_tender_amount_$index'),
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
                onTap: onSelected,
                onChanged: (_) => onAmountChanged(),
                decoration: InputDecoration(labelText: amountLabel),
              );
              final methodField = DropdownButtonFormField<PaymentMethod>(
                key: ValueKey('payment_tender_method_$index'),
                initialValue: method,
                decoration: InputDecoration(labelText: methodLabel),
                items: [
                  for (final paymentMethod in enabledMethods)
                    DropdownMenuItem(
                      value: paymentMethod,
                      child: Text(paymentMethodLabel(l10n, paymentMethod)),
                    ),
                ],
                onChanged: (nextMethod) {
                  if (nextMethod != null) {
                    onMethodChanged(nextMethod);
                  }
                },
              );

              final header = Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('payment_tender_remove_$index'),
                    tooltip: removeTooltip,
                    onPressed: canRemove ? onRemove : null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              );

              if (constraints.maxWidth < 420) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    SizedBox(height: spacing.sm),
                    methodField,
                    SizedBox(height: spacing.sm),
                    amountField,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  SizedBox(height: spacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: methodField),
                      SizedBox(width: spacing.sm),
                      SizedBox(width: 160, child: amountField),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
