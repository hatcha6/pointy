import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../shared/money_text.dart';

/// What the wallet asks of the payer, asked only after "pay" (the same rule
/// as the shop wallet: nothing inline under the method list). Returns the
/// payer's number (phone or wallet card) and, for Sadad, the birth year.
Future<(String, String)?> showPayerDialog(
  BuildContext context, {
  required PaymentMethod method,
  required Money amount,
  String phone = '',
}) {
  return showDialog<(String, String)>(
    context: context,
    builder: (_) => _PayerDialog(method: method, amount: amount, phone: phone),
  );
}

class _PayerDialog extends StatefulWidget {
  const _PayerDialog({
    required this.method,
    required this.amount,
    required this.phone,
  });

  final PaymentMethod method;
  final Money amount;
  final String phone;

  @override
  State<_PayerDialog> createState() => _PayerDialogState();
}

class _PayerDialogState extends State<_PayerDialog> {
  late final _payer = TextEditingController(
    text: widget.method.payer == 'phone' ? widget.phone : '',
  );
  final _year = TextEditingController();
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _payer.dispose();
    _year.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final method = widget.method;
    final mark = PaymentMethodMarks.of(method.provider);
    final numeric = PointyTypography.numeric(theme.textTheme.titleMedium!);
    return AlertDialog(
      title: Row(
        children: [
          if (mark != null) ...[
            SizedBox(height: 28, width: 44, child: Image(image: mark)),
            const SizedBox(width: CardsSpace.sm),
          ],
          Expanded(child: Text(l10n.payerTitle(method.name))),
        ],
      ),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.payAmount(formatMoney(l10n, widget.amount)),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: CardsSpace.lg),
            if (method.payer.isNotEmpty)
              TextFormField(
                controller: _payer,
                autofocus: _payer.text.isEmpty,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                ],
                style: numeric,
                decoration: InputDecoration(
                  labelText: method.payer == 'phone'
                      ? l10n.payerPhone
                      : l10n.payerCard,
                ),
                validator: (value) =>
                    (value ?? '').replaceAll(' ', '').length < 6
                    ? l10n.errInvalidPayer
                    : null,
              ),
            if (method.birthYear) ...[
              const SizedBox(height: CardsSpace.md),
              TextFormField(
                controller: _year,
                autofocus: _payer.text.isNotEmpty,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                style: numeric,
                decoration: InputDecoration(
                  labelText: l10n.payerBirthYear,
                  hintText: '1990',
                ),
                validator: (value) {
                  final year = int.tryParse(value ?? '');
                  return year == null ||
                          year < 1900 ||
                          year > DateTime.now().year
                      ? l10n.errInvalidPayer
                      : null;
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(120, CardsSizes.touch),
          ),
          onPressed: () {
            if (_form.currentState!.validate()) {
              Navigator.of(context)
                  .pop((_payer.text.replaceAll(' ', ''), _year.text));
            }
          },
          child: Text(l10n.continueAction),
        ),
      ],
    );
  }
}
