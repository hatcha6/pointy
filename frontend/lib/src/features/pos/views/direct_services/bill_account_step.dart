import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_kinds.dart';
import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../direct_services/arabic_search_text.dart';
import '../../view_models/bill_flow_view_model.dart';
import 'service_texts.dart';

/// Keeps a meter, account or invoice number to what such numbers are made of:
/// letters and digits (Arabic digits become ASCII), `-`, `_` and `/`.
class BillNumberFormatter extends TextInputFormatter {
  const BillNumberFormatter({
    required this.maxLength,
    this.allowSpaces = false,
  });

  final int maxLength;
  final bool allowSpaces;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final pattern = allowSpaces ? r'[^A-Za-z0-9\-_/ ]' : r'[^A-Za-z0-9\-_/]';
    var cleaned = asciiDigits(newValue.text).replaceAll(RegExp(pattern), '');
    if (cleaned.length > maxLength) {
      cleaned = cleaned.substring(0, maxLength);
    }
    if (cleaned == newValue.text) {
      return newValue;
    }
    final removed = newValue.text.length - cleaned.length;
    return TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(
        offset: (newValue.selection.baseOffset - removed).clamp(
          0,
          cleaned.length,
        ),
      ),
    );
  }
}

/// Step three of a bill: the number printed on it — a meter, an account, a
/// subscription card — with the right name and an example for the type, and,
/// for a postpaid bill that is settled against an invoice, the invoice
/// number as well. LTR fields, because that is how such numbers are read.
class BillAccountStep extends StatefulWidget {
  const BillAccountStep({super.key, required this.viewModel});

  final BillFlowViewModel viewModel;

  @override
  State<BillAccountStep> createState() => _BillAccountStepState();
}

class _BillAccountStepState extends State<BillAccountStep> {
  late final TextEditingController _account = TextEditingController(
    text: widget.viewModel.account,
  );
  late final TextEditingController _invoice = TextEditingController(
    text: widget.viewModel.invoice,
  );
  final FocusNode _invoiceFocus = FocusNode();

  @override
  void dispose() {
    _account.dispose();
    _invoice.dispose();
    _invoiceFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final vm = widget.viewModel;
    final biller = vm.biller;
    final needsInvoice = vm.needsInvoice;
    final accountLabel = needsInvoice
        ? l10n.posBillAccountLabelContract
        : billAccountLabel(l10n, vm.type);
    final example = billAccountExample(l10n, vm.type);
    final isPrepaidElectricity =
        vm.type == BillType.electricity && (biller?.isPrepaid ?? false);
    // An example is a hint, not a value: lighter and plainer than what is
    // typed, so a cashier never mistakes it for the number already entered.
    final hintStyle = PointyTypography.numeric(
      (textTheme.titleMedium ?? const TextStyle()).copyWith(
        color: colors.mutedInk.withValues(alpha: 0.55),
        fontWeight: FontWeight.w500,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScanWedgeTarget(
          child: TextField(
            key: const ValueKey('bill_account_field'),
            controller: _account,
            autofocus: true,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.start,
            textInputAction: needsInvoice
                ? TextInputAction.next
                : TextInputAction.done,
            inputFormatters: const [
              BillNumberFormatter(
                maxLength: BillFlowViewModel.maxAccountLength,
              ),
            ],
            onChanged: vm.setAccount,
            onSubmitted: (_) {
              if (needsInvoice) {
                _invoiceFocus.requestFocus();
              } else {
                vm.continueFromAccount();
              }
            },
            style: PointyTypography.numeric(
              (textTheme.titleMedium ?? const TextStyle()).copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
            decoration: InputDecoration(
              labelText: accountLabel,
              hintText: example,
              hintStyle: hintStyle,
              hintTextDirection: TextDirection.ltr,
              helperText: l10n.posBillExample(example),
            ),
          ),
        ),
        if (needsInvoice) ...[
          const SizedBox(height: 14),
          ScanWedgeTarget(
            child: TextField(
              key: const ValueKey('bill_invoice_field'),
              controller: _invoice,
              focusNode: _invoiceFocus,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.start,
              textInputAction: TextInputAction.done,
              inputFormatters: const [
                BillNumberFormatter(
                  maxLength: BillFlowViewModel.maxInvoiceLength,
                ),
              ],
              onChanged: vm.setInvoice,
              onSubmitted: (_) => vm.continueFromAccount(),
              style: PointyTypography.numeric(
                (textTheme.titleMedium ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              decoration: InputDecoration(
                labelText: l10n.posBillInvoiceLabel,
                hintText: l10n.posBillInvoiceExample,
                hintStyle: hintStyle,
                hintTextDirection: TextDirection.ltr,
                helperText: l10n.posBillInvoiceHelp,
                helperMaxLines: 2,
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        PointyInlineMessage.warning(
          key: const ValueKey('bill_check_number'),
          message: l10n.posBillCheckNumber,
          icon: Icons.fact_check_outlined,
          compact: true,
        ),
        if (isPrepaidElectricity) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.confirmation_number_outlined,
                size: 17,
                color: colors.primaryStrong,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.posBillPrepaidNote,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.primaryDark,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
