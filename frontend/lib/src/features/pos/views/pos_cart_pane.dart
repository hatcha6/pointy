import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order_totals.dart';
import '../../../shared/payment_labels.dart';
import '../models/split_tender_payment.dart';
import '../view_models/pos_view_model.dart';
import 'cart_line_tile.dart';
import 'cart_totals.dart';

class PosCartPane extends StatelessWidget {
  const PosCartPane({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        final isCartLocked = viewModel.isCheckingOut || !canCheckout;

        return ColoredBox(
          color: Colors.white,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.currentSaleTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.clearCartTooltip,
                        visualDensity: VisualDensity.compact,
                        onPressed: viewModel.cart.isEmpty || isCartLocked
                            ? null
                            : viewModel.clearCart,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ContactSelectionTile(
                    label: l10n.selectedCustomerLabel,
                    value: viewModel.selectedCustomer?.fullName ?? '',
                    placeholder: l10n.walkInCustomerLabel,
                    icon: Icons.person_outline,
                    iconSize: 20,
                    iconSpacing: 8,
                    enabled: !viewModel.isCheckingOut,
                    onSelect: () => _selectCustomer(context),
                    onClear: () => viewModel.selectCustomer(null),
                    padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 6, 8),
                    actionVisualDensity: VisualDensity.compact,
                    selectActionIcon: Icons.edit_outlined,
                  ),
                  const SizedBox(height: 8),
                  _CouponCodeField(viewModel: viewModel),
                  const SizedBox(height: 8),
                  Expanded(
                    child: viewModel.cart.isEmpty
                        ? Center(
                            child: Text(
                              l10n.emptyCart,
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.separated(
                            padding: EdgeInsets.zero,
                            itemCount: viewModel.cart.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final line = viewModel.cart[index];
                              return CartLineTile(
                                line: line,
                                onAdd: isCartLocked
                                    ? null
                                    : () => viewModel.addProduct(line.product),
                                onRemove: isCartLocked
                                    ? null
                                    : () => viewModel.decrementProduct(
                                        line.product,
                                      ),
                              );
                            },
                          ),
                  ),
                  _CheckoutFooter(
                    viewModel: viewModel,
                    capabilities: capabilities,
                    onCheckout: () => _checkout(context),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _checkout(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final shortages = viewModel.checkoutStockShortages();
    if (shortages.isNotEmpty) {
      final shouldContinue = await _showStockWarningDialog(
        context,
        shortages: shortages,
        canOversell: viewModel.allowOverselling,
      );
      if (shouldContinue != true) {
        return;
      }
      if (!context.mounted) {
        return;
      }
    }

    await viewModel.refreshDiscountPreview();
    if (!context.mounted) {
      return;
    }
    if (viewModel.hasDiscountPreviewError) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.discountPreviewUnavailable)),
        );
      return;
    }
    if (viewModel.unappliedCouponCodes.isNotEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.discountCouponUnavailable(
                viewModel.unappliedCouponCodes.join('، '),
              ),
            ),
          ),
        );
      return;
    }

    final payment = await _showPaymentDialog(context);
    if (payment == null) {
      return;
    }

    final outcome = await viewModel.checkoutCurrentSale(
      payments: payment.payments,
    );

    if (!context.mounted) {
      return;
    }

    if (outcome.isStockRejected) {
      await _showStockWarningDialog(
        context,
        shortages: outcome.shortages,
        canOversell: false,
      );
      return;
    }

    final receiptNumber = outcome.order?.receiptNumber;
    var message = outcome.isSuccess
        ? receiptNumber == null || receiptNumber.isEmpty
              ? l10n.saleCheckoutSuccess
              : l10n.saleCheckoutSuccessWithReceipt(receiptNumber)
        : l10n.saleCheckoutError;
    if (outcome.isSuccess) {
      message = switch (outcome.printStatus) {
        InvoicePrintStatus.printed => '$message ${l10n.invoicePrintSuccess}',
        InvoicePrintStatus.failed => '$message ${l10n.invoicePrintError}',
        InvoicePrintStatus.notRequested => message,
      };
    }

    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selectCustomer(BuildContext context) async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: contactRepository,
    );
    if (customer != null) {
      viewModel.selectCustomer(customer);
    }
  }

  Future<bool?> _showStockWarningDialog(
    BuildContext context, {
    required List<SaleStockShortage> shortages,
    required bool canOversell,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.warning_amber_outlined),
          title: Text(l10n.oversellWarningTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  canOversell
                      ? l10n.oversellWarningMessage
                      : l10n.oversellBlockedMessage,
                ),
                const SizedBox(height: 12),
                for (final shortage in shortages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      l10n.oversellLine(
                        shortage.productName,
                        shortage.requested,
                        shortage.available,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                canOversell ? l10n.cancelButton : l10n.reviewCartButton,
              ),
            ),
            if (canOversell)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.continueSaleButton),
              ),
          ],
        );
      },
    );
  }

  Future<_PaymentInput?> _showPaymentDialog(BuildContext context) {
    return showDialog<_PaymentInput>(
      context: context,
      builder: (context) => _PaymentDialog(viewModel: viewModel),
    );
  }
}

class _CouponCodeField extends StatefulWidget {
  const _CouponCodeField({required this.viewModel});

  final PosViewModel viewModel;

  @override
  State<_CouponCodeField> createState() => _CouponCodeFieldState();
}

class _CouponCodeFieldState extends State<_CouponCodeField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.viewModel.couponCode,
  );
  final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(covariant _CouponCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus &&
        _controller.text != widget.viewModel.couponCode) {
      _controller.text = widget.viewModel.couponCode;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;
    final hasCoupon = _controller.text.trim().isNotEmpty;
    final hasInvalidCoupon = viewModel.unappliedCouponCodes.isNotEmpty;

    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      enabled: !viewModel.isCheckingOut,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: l10n.discountCouponCodeLabel,
        hintText: l10n.discountCouponCodeHint,
        isDense: true,
        prefixIcon: const Icon(Icons.confirmation_number_outlined),
        suffixIcon: viewModel.isLoadingDiscountPreview
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: hasCoupon
                    ? l10n.clearCouponCodeTooltip
                    : l10n.refreshDiscountPreviewTooltip,
                onPressed: viewModel.isCheckingOut
                    ? null
                    : () {
                        if (hasCoupon) {
                          _controller.clear();
                          viewModel.updateCouponCode('');
                        } else {
                          viewModel.refreshDiscountPreview();
                        }
                      },
                icon: Icon(hasCoupon ? Icons.close : Icons.sync),
              ),
        errorText: hasInvalidCoupon
            ? l10n.discountCouponUnavailable(
                viewModel.unappliedCouponCodes.join('، '),
              )
            : viewModel.hasDiscountPreviewError
            ? l10n.discountPreviewUnavailable
            : null,
      ),
      onChanged: viewModel.updateCouponCode,
      onSubmitted: (_) => viewModel.refreshDiscountPreview(),
    );
  }
}

class _CheckoutFooter extends StatelessWidget {
  const _CheckoutFooter({
    required this.viewModel,
    required this.capabilities,
    required this.onCheckout,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canSubmit = viewModel.cart.isNotEmpty && !viewModel.isCheckingOut;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CartTotals(viewModel: viewModel),
            if (viewModel.shouldShowPrintInvoiceCheckbox)
              CheckboxListTile(
                value: viewModel.printInvoiceAfterPayment,
                onChanged: viewModel.isCheckingOut
                    ? null
                    : (value) => viewModel.updatePrintInvoiceAfterPayment(
                        value ?? false,
                      ),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  l10n.printInvoiceAfterPaymentLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 8),
            CheckoutGuard(
              capabilities: capabilities,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: canSubmit ? onCheckout : null,
                icon: viewModel.isCheckingOut
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.payments_outlined),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    viewModel.isCheckingOut
                        ? l10n.checkoutInProgressButton
                        : l10n.payAmount(formatMoney(viewModel.total)),
                    maxLines: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.viewModel});

  final PosViewModel viewModel;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  static const _paymentCalculator = SplitTenderPaymentCalculator();

  late final List<_TenderLineInput> _tenders = [
    _TenderLineInput(
      method: _initialMethod,
      amount: widget.viewModel.total.toStringAsFixed(2),
    ),
  ];
  bool _showPaymentError = false;
  bool _isBalancingTender = false;

  @override
  void dispose() {
    for (final tender in _tenders) {
      tender.dispose();
    }
    super.dispose();
  }

  PaymentMethod get _initialMethod {
    if (widget.viewModel.enableCashPayments) {
      return PaymentMethod.cash;
    }
    if (widget.viewModel.enableCardPayments) {
      return PaymentMethod.card;
    }
    return PaymentMethod.transfer;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final total = widget.viewModel.total;
    final summary = _paymentCalculator.summary(
      total: total,
      tenders: _tenderInputs,
    );

    return AlertDialog(
      icon: const Icon(Icons.payments_outlined),
      title: Text(l10n.paymentDialogTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_hasAnyPaymentMethod)
                Text(l10n.noEnabledPaymentMethods)
              else ...[
                for (var index = 0; index < _tenders.length; index++) ...[
                  _TenderLineEditor(
                    key: ValueKey(_tenders[index]),
                    index: index,
                    tender: _tenders[index],
                    enabledMethods: _enabledMethods,
                    canRemove: _tenders.length > 1,
                    methodLabel: (method) => paymentMethodLabel(l10n, method),
                    onAmountChanged: () => _rebalanceFromTender(index),
                    onMethodChanged: () =>
                        setState(() => _showPaymentError = false),
                    onRemove: () => _removeTender(index),
                  ),
                  const SizedBox(height: 10),
                ],
                OutlinedButton.icon(
                  onPressed: _addTender,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addSplitTenderButton),
                ),
              ],
              const SizedBox(height: 16),
              TotalRow(label: l10n.total, value: total, isStrong: true),
              TotalRow(label: l10n.paidAmountLabel, value: summary.paid),
              TotalRow(
                label: l10n.remainingAmountLabel,
                value: summary.remaining,
              ),
              if (summary.changeDue > 0)
                TotalRow(label: l10n.changeDueLabel, value: summary.changeDue),
              if (_showPaymentError) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.paymentTotalTooLowError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          onPressed: _hasAnyPaymentMethod ? () => _submit(total) : null,
          icon: const Icon(Icons.check),
          label: Text(l10n.confirmPaymentButton),
        ),
      ],
    );
  }

  void _submit(double total) {
    final payments = _appliedPayments(total);
    if (payments == null) {
      setState(() => _showPaymentError = true);
      return;
    }
    Navigator.of(context).pop(_PaymentInput(payments: payments));
  }

  void _addTender() {
    final summary = _paymentCalculator.summary(
      total: widget.viewModel.total,
      tenders: _tenderInputs,
    );
    setState(() {
      _tenders.add(
        _TenderLineInput(
          method: _nextTenderMethod,
          amount: summary.remaining > 0
              ? summary.remaining.toStringAsFixed(2)
              : '',
        ),
      );
      _showPaymentError = false;
    });
  }

  void _removeTender(int index) {
    setState(() {
      _tenders.removeAt(index).dispose();
      _rebalanceAfterTenderRemoval();
      _showPaymentError = false;
    });
  }

  void _rebalanceAfterTenderRemoval() {
    if (_tenders.isEmpty) {
      return;
    }

    final balanceIndex = _tenders.length - 1;
    final balanceAmount = _paymentCalculator.balanceTenderAmount(
      total: widget.viewModel.total,
      tenders: _tenderInputs,
      balanceIndex: balanceIndex,
    );
    _setTenderAmount(_tenders[balanceIndex], balanceAmount);
  }

  void _rebalanceFromTender(int editedIndex) {
    if (_isBalancingTender) {
      return;
    }
    if (_tenders.length < 2) {
      setState(() => _showPaymentError = false);
      return;
    }

    _isBalancingTender = true;
    final balanceIndex = _paymentCalculator.balanceTenderIndex(
      editedIndex: editedIndex,
      tenderCount: _tenders.length,
    );
    final balanceAmount = _paymentCalculator.balanceTenderAmount(
      total: widget.viewModel.total,
      tenders: _tenderInputs,
      balanceIndex: balanceIndex,
    );
    _setTenderAmount(_tenders[balanceIndex], balanceAmount);
    _isBalancingTender = false;
    setState(() => _showPaymentError = false);
  }

  void _setTenderAmount(_TenderLineInput tender, double amount) {
    final text = amount > 0 ? amount.toStringAsFixed(2) : '';
    if (tender.amountController.text == text) {
      return;
    }
    tender.amountController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  List<SaleCheckoutPaymentDraft>? _appliedPayments(double total) {
    return _paymentCalculator.appliedPayments(
      total: total,
      tenders: _tenderInputs,
    );
  }

  List<SplitTenderInput> get _tenderInputs {
    return [
      for (final tender in _tenders)
        SplitTenderInput(
          method: tender.method,
          amount: _paymentCalculator.parseAmount(tender.amountController.text),
        ),
    ];
  }

  bool get _hasAnyPaymentMethod {
    return widget.viewModel.enableCashPayments ||
        widget.viewModel.enableCardPayments ||
        widget.viewModel.enableTransferPayments;
  }

  List<PaymentMethod> get _enabledMethods {
    return [
      if (widget.viewModel.enableCashPayments) PaymentMethod.cash,
      if (widget.viewModel.enableCardPayments) PaymentMethod.card,
      if (widget.viewModel.enableTransferPayments) PaymentMethod.transfer,
    ];
  }

  PaymentMethod get _nextTenderMethod {
    final usedMethods = _tenders.map((tender) => tender.method).toSet();
    for (final method in _enabledMethods) {
      if (!usedMethods.contains(method)) {
        return method;
      }
    }
    return _initialMethod;
  }
}

class _PaymentInput {
  const _PaymentInput({required this.payments});

  final List<SaleCheckoutPaymentDraft> payments;
}

class _TenderLineInput {
  _TenderLineInput({required this.method, required String amount})
    : amountController = TextEditingController(text: amount);

  PaymentMethod method;
  final TextEditingController amountController;

  void dispose() {
    amountController.dispose();
  }
}

class _TenderLineEditor extends StatelessWidget {
  const _TenderLineEditor({
    super.key,
    required this.index,
    required this.tender,
    required this.enabledMethods,
    required this.canRemove,
    required this.methodLabel,
    required this.onAmountChanged,
    required this.onMethodChanged,
    required this.onRemove,
  });

  final int index;
  final _TenderLineInput tender;
  final List<PaymentMethod> enabledMethods;
  final bool canRemove;
  final String Function(PaymentMethod method) methodLabel;
  final VoidCallback onAmountChanged;
  final VoidCallback onMethodChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: DropdownButtonFormField<PaymentMethod>(
            initialValue: tender.method,
            decoration: InputDecoration(
              labelText: l10n.paymentMethodLabel,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final method in enabledMethods)
                DropdownMenuItem(
                  value: method,
                  child: Text(methodLabel(method)),
                ),
            ],
            onChanged: (method) {
              if (method == null) {
                return;
              }
              tender.method = method;
              onMethodChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 132,
          child: TextField(
            key: ValueKey('payment_tender_amount_$index'),
            controller: tender.amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            onChanged: (_) => onAmountChanged(),
            decoration: InputDecoration(
              labelText: l10n.paymentTenderAmountLabel,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          key: ValueKey('payment_tender_remove_$index'),
          tooltip: l10n.removeTenderTooltip,
          onPressed: canRemove ? onRemove : null,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }
}
