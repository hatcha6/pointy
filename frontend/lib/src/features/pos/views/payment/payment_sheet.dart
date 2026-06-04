import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/card_payment_receipt.dart';
import '../../../../data/models/sale_order.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../../../shared/components/components.dart';
import '../../models/split_tender_payment.dart';
import 'card_receipt_validation_dialog.dart';
import 'payment_method_segmented_control.dart';
import 'pointy_amount_display.dart';
import 'pointy_keypad.dart';
import 'quick_amount_bar.dart';
import 'receipt_toggle_row.dart';
import 'tender_line_editor.dart';

class PaymentSheetResult {
  const PaymentSheetResult({required this.payments});

  final List<SaleCheckoutPaymentDraft> payments;
}

Future<PaymentSheetResult?> showPosPaymentSheet({
  required BuildContext context,
  required double total,
  required bool enableCashPayments,
  required bool enableCardPayments,
  required bool enableTransferPayments,
  required bool requireCardReceipt,
  required List<String> trustedCardTerminalIds,
  required bool showPrintInvoiceToggle,
  required bool printInvoiceAfterPayment,
  required ValueChanged<bool> onPrintInvoiceChanged,
}) {
  final width = MediaQuery.sizeOf(context).width;
  Widget childBuilder(BuildContext modalContext) {
    return PaymentSheet(
      total: total,
      enableCashPayments: enableCashPayments,
      enableCardPayments: enableCardPayments,
      enableTransferPayments: enableTransferPayments,
      requireCardReceipt: requireCardReceipt,
      trustedCardTerminalIds: trustedCardTerminalIds,
      showPrintInvoiceToggle: showPrintInvoiceToggle,
      printInvoiceAfterPayment: printInvoiceAfterPayment,
      onPrintInvoiceChanged: onPrintInvoiceChanged,
      onCancel: () => Navigator.of(modalContext).pop(),
      onSubmit: (result) => Navigator.of(modalContext).pop(result),
    );
  }

  if (width < AppBreakpoints.tabletMin) {
    return showAdaptiveModalBottomSheet<PaymentSheetResult>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 1,
      builder: childBuilder,
    );
  }

  return showDialog<PaymentSheetResult>(
    context: context,
    builder: (dialogContext) {
      return AdaptiveDialogSurface(
        size: AdaptiveModalSize.expanded,
        maxWidth: 1120,
        maxHeightFactor: 0.98,
        child: childBuilder(dialogContext),
      );
    },
  );
}

class PaymentSheet extends StatefulWidget {
  const PaymentSheet({
    super.key,
    required this.total,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.requireCardReceipt,
    required this.trustedCardTerminalIds,
    required this.showPrintInvoiceToggle,
    required this.printInvoiceAfterPayment,
    required this.onPrintInvoiceChanged,
    required this.onSubmit,
    required this.onCancel,
  });

  final double total;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardReceipt;
  final List<String> trustedCardTerminalIds;
  final bool showPrintInvoiceToggle;
  final bool printInvoiceAfterPayment;
  final ValueChanged<bool> onPrintInvoiceChanged;
  final ValueChanged<PaymentSheetResult> onSubmit;
  final VoidCallback onCancel;

  @override
  State<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  static const _calculator = SplitTenderPaymentCalculator();

  final List<_TenderLineInput> _tenders = [];
  var _activeTenderIndex = 0;
  var _showPaymentError = false;
  var _isBalancingTender = false;
  late var _printInvoiceAfterPayment = widget.printInvoiceAfterPayment;

  @override
  void initState() {
    super.initState();
    final methods = _enabledMethods;
    if (methods.isNotEmpty) {
      _tenders.add(
        _TenderLineInput(
          method: methods.first,
          amount: widget.total.toStringAsFixed(2),
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final tender in _tenders) {
      tender.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final summary = _summary;

    return Material(
      key: const ValueKey('payment_sheet'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.sheet),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _PaymentHeader(
              title: l10n.paymentDialogTitle,
              onCancel: widget.onCancel,
            ),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide =
                      constraints.maxWidth >= AppBreakpoints.tabletMin;
                  return SingleChildScrollView(
                    padding: spacing.sectionPadding,
                    child: isWide
                        ? _buildWidePaymentLayout(l10n, summary)
                        : _buildNarrowPaymentLayout(l10n, summary),
                  );
                },
              ),
            ),
            PointyStickyActionFooter(
              secondaryActions: [
                TextButton(
                  key: const ValueKey('payment_cancel_button'),
                  onPressed: widget.onCancel,
                  child: Text(l10n.cancelButton),
                ),
              ],
              primaryAction: FilledButton.icon(
                key: const ValueKey('payment_confirm_button'),
                onPressed: _canSubmit ? _submit : null,
                icon: const Icon(Icons.check),
                label: Text(l10n.confirmPaymentButton),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWidePaymentLayout(
    AppLocalizations l10n,
    SplitTenderPaymentSummary summary,
  ) {
    final spacing = AdaptiveSpacing.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildPaymentControls(l10n, includeKeypad: false)),
        SizedBox(width: spacing.lg),
        SizedBox(width: 240, child: _buildKeypad(l10n)),
        SizedBox(width: spacing.lg),
        SizedBox(width: 280, child: _buildSummaryPanel(l10n, summary)),
      ],
    );
  }

  Widget _buildNarrowPaymentLayout(
    AppLocalizations l10n,
    SplitTenderPaymentSummary summary,
  ) {
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSummaryPanel(l10n, summary),
        SizedBox(height: spacing.lg),
        _buildPaymentControls(l10n, includeKeypad: false),
      ],
    );
  }

  Widget _buildPaymentControls(
    AppLocalizations l10n, {
    bool includeKeypad = true,
  }) {
    final spacing = AdaptiveSpacing.of(context);
    final activeTender = _activeTender;

    if (_enabledMethods.isEmpty) {
      return PointyErrorState(
        title: l10n.noEnabledPaymentMethods,
        icon: Icons.payments_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaymentMethodSegmentedControl(
          label: l10n.paymentMethodLabel,
          enabledMethods: _enabledMethods,
          selectedMethod: activeTender?.method,
          splitTenderEnabled: _canUseSplitTenderMode,
          splitTenderSelected: _isSplitTenderMode,
          onSelected: _selectSinglePaymentMethod,
          onSplitTenderSelected: _selectSplitTenderMode,
        ),
        SizedBox(height: spacing.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('payment_add_tender'),
            onPressed: _addTender,
            icon: const Icon(Icons.add),
            label: Text(l10n.addSplitTenderButton),
          ),
        ),
        SizedBox(height: spacing.md),
        if (activeTender?.method == PaymentMethod.cash) ...[
          QuickAmountBar(
            label: l10n.paymentQuickAmountsLabel,
            amounts: _quickAmounts,
            onSelected: (amount) =>
                _setTenderAmount(_activeTenderIndex, amount.toStringAsFixed(2)),
          ),
          SizedBox(height: spacing.md),
        ],
        if (includeKeypad) ...[
          _buildKeypad(l10n),
          SizedBox(height: spacing.md),
        ],
        for (final entry in _tenders.indexed) ...[
          if (entry.$1 > 0) SizedBox(height: spacing.sm),
          TenderLineEditor(
            index: entry.$1,
            title: l10n.paymentTenderLineTitle(entry.$1 + 1),
            amountLabel: l10n.paymentTenderAmountLabel,
            methodLabel: l10n.paymentMethodLabel,
            removeTooltip: l10n.removeTenderTooltip,
            amountController: entry.$2.amountController,
            method: entry.$2.method,
            enabledMethods: _enabledMethods,
            canRemove: _tenders.length > 1,
            isSelected: entry.$1 == _activeTenderIndex,
            onSelected: () => setState(() => _activeTenderIndex = entry.$1),
            onAmountChanged: () => _rebalanceFromTender(entry.$1),
            onMethodChanged: (method) => _updateTenderMethod(entry.$1, method),
            onRemove: () => _removeTender(entry.$1),
            requireCardReceipt: widget.requireCardReceipt,
            cardReceipt: entry.$2.cardReceipt,
            canValidateCardReceipt:
                entry.$2.method == PaymentMethod.card &&
                _calculator.parseAmount(entry.$2.amountController.text) > 0,
            onValidateCardReceipt: () => _validateCardReceipt(entry.$1),
          ),
        ],
        if (widget.showPrintInvoiceToggle) ...[
          SizedBox(height: spacing.md),
          ReceiptToggleRow(
            label: l10n.printInvoiceAfterPaymentLabel,
            subtitle: l10n.receiptToggleSubtitle,
            tooltip: l10n.receiptToggleTooltip,
            value: _printInvoiceAfterPayment,
            onChanged: (value) {
              setState(() => _printInvoiceAfterPayment = value);
              widget.onPrintInvoiceChanged(value);
            },
          ),
        ],
      ],
    );
  }

  Widget _buildKeypad(AppLocalizations l10n) {
    return PointyKeypad(
      label: l10n.paymentKeypadLabel,
      backspaceTooltip: l10n.paymentKeypadBackspaceTooltip,
      clearTooltip: l10n.paymentKeypadClearTooltip,
      onDigit: _appendDigit,
      onDecimal: _appendDecimal,
      onBackspace: _backspace,
      onClear: _clearActiveTenderAmount,
    );
  }

  Widget _buildSummaryPanel(
    AppLocalizations l10n,
    SplitTenderPaymentSummary summary,
  ) {
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PointyAmountDisplay(
          key: const ValueKey('payment_amount_display'),
          label: l10n.amountDueLabel,
          value: formatMoney(widget.total),
          tone: PointyAmountDisplayTone.primary,
          emphasized: true,
        ),
        SizedBox(height: spacing.sm),
        PointyAmountDisplay(
          label: l10n.paidAmountLabel,
          value: formatMoney(summary.paid),
        ),
        SizedBox(height: spacing.sm),
        PointyAmountDisplay(
          label: summary.changeDue > 0
              ? l10n.changeDueLabel
              : l10n.remainingAmountLabel,
          value: formatMoney(
            summary.changeDue > 0 ? summary.changeDue : summary.remaining,
          ),
          tone: summary.changeDue > 0
              ? PointyAmountDisplayTone.success
              : PointyAmountDisplayTone.warning,
        ),
        if (_showPaymentError || !_canSubmit) ...[
          SizedBox(height: spacing.sm),
          Text(
            _enabledMethods.isEmpty
                ? l10n.noEnabledPaymentMethods
                : _hasMissingRequiredCardReceipt
                ? l10n.cardReceiptRequiredError
                : l10n.paymentTotalTooLowError,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: context.pointyColors.danger),
          ),
        ],
      ],
    );
  }

  void _submit() {
    final payments = _appliedPayments;
    if (payments == null || _hasMissingRequiredCardReceipt) {
      setState(() => _showPaymentError = true);
      return;
    }
    widget.onSubmit(PaymentSheetResult(payments: payments));
  }

  Future<void> _validateCardReceipt(int index) async {
    if (index < 0 || index >= _tenders.length) {
      return;
    }
    final tender = _tenders[index];
    final amount = _calculator.parseAmount(tender.amountController.text);
    if (tender.method != PaymentMethod.card || amount <= 0) {
      return;
    }

    final receipt = await showCardReceiptValidationDialog(
      context: context,
      expectedAmount: amount,
      trustedTerminalIds: widget.trustedCardTerminalIds,
    );
    if (receipt == null || !mounted) {
      return;
    }

    setState(() {
      tender.cardReceipt = receipt;
      _activeTenderIndex = index;
      _showPaymentError = false;
    });
  }

  void _addTender() {
    final methods = _enabledMethods;
    if (methods.isEmpty) {
      return;
    }

    final summary = _summary;
    setState(() {
      _tenders.add(
        _TenderLineInput(
          method: _nextTenderMethod,
          amount: summary.remaining > 0
              ? summary.remaining.toStringAsFixed(2)
              : '',
        ),
      );
      _activeTenderIndex = _tenders.length - 1;
      _showPaymentError = false;
    });
  }

  void _removeTender(int index) {
    setState(() {
      _tenders.removeAt(index).dispose();
      if (_activeTenderIndex >= _tenders.length) {
        _activeTenderIndex = math.max(0, _tenders.length - 1);
      }
      _rebalanceAfterTenderRemoval();
      _showPaymentError = false;
    });
  }

  void _rebalanceAfterTenderRemoval() {
    if (_tenders.isEmpty) {
      return;
    }

    final balanceIndex = _tenders.length - 1;
    final balanceAmount = _calculator.balanceTenderAmount(
      total: widget.total,
      tenders: _tenderInputs,
      balanceIndex: balanceIndex,
    );
    _setTenderAmount(
      balanceIndex,
      balanceAmount > 0 ? balanceAmount.toStringAsFixed(2) : '',
      rebalance: false,
    );
  }

  void _rebalanceFromTender(int editedIndex) {
    if (_isBalancingTender) {
      return;
    }
    if (_tenders.length < 2) {
      setState(() {
        _activeTenderIndex = editedIndex;
        _showPaymentError = false;
      });
      return;
    }

    _isBalancingTender = true;
    final balanceIndex = _calculator.balanceTenderIndex(
      editedIndex: editedIndex,
      tenderCount: _tenders.length,
    );
    final balanceAmount = _calculator.balanceTenderAmount(
      total: widget.total,
      tenders: _tenderInputs,
      balanceIndex: balanceIndex,
    );
    _setTenderAmount(
      balanceIndex,
      balanceAmount > 0 ? balanceAmount.toStringAsFixed(2) : '',
      rebalance: false,
    );
    _isBalancingTender = false;
    setState(() {
      _activeTenderIndex = editedIndex;
      _showPaymentError = false;
    });
  }

  void _updateTenderMethod(int index, PaymentMethod method) {
    setState(() {
      _tenders[index].method = method;
      if (method != PaymentMethod.card) {
        _tenders[index].cardReceipt = null;
      }
      _activeTenderIndex = index;
      _showPaymentError = false;
    });
  }

  void _selectSinglePaymentMethod(PaymentMethod method) {
    if (_tenders.isEmpty) {
      return;
    }

    setState(() {
      while (_tenders.length > 1) {
        _tenders.removeLast().dispose();
      }
      final tender = _tenders.first;
      tender.method = method;
      if (method != PaymentMethod.card) {
        tender.cardReceipt = null;
      }
      _activeTenderIndex = 0;
      _showPaymentError = false;
      _setTenderAmount(0, widget.total.toStringAsFixed(2), rebalance: false);
    });
  }

  void _selectSplitTenderMode() {
    if (!_canUseSplitTenderMode || _tenders.length > 1) {
      return;
    }
    _addTender();
  }

  void _appendDigit(String digit) {
    final tender = _activeTender;
    if (tender == null) {
      return;
    }
    final current = tender.amountController.text;
    final next = current == '0' ? digit : '$current$digit';
    _setTenderAmount(_activeTenderIndex, _normalizedAmountText(next));
  }

  void _appendDecimal() {
    final tender = _activeTender;
    if (tender == null) {
      return;
    }
    final current = tender.amountController.text;
    if (current.contains('.')) {
      return;
    }
    _setTenderAmount(_activeTenderIndex, current.isEmpty ? '0.' : '$current.');
  }

  void _backspace() {
    final tender = _activeTender;
    if (tender == null) {
      return;
    }
    final current = tender.amountController.text;
    if (current.isEmpty) {
      return;
    }
    _setTenderAmount(
      _activeTenderIndex,
      current.substring(0, current.length - 1),
    );
  }

  void _clearActiveTenderAmount() {
    if (_activeTender == null) {
      return;
    }
    _setTenderAmount(_activeTenderIndex, '');
  }

  void _setTenderAmount(int index, String text, {bool rebalance = true}) {
    if (index < 0 || index >= _tenders.length) {
      return;
    }
    final tender = _tenders[index];
    if (tender.amountController.text != text) {
      tender.amountController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _clearMismatchedCardReceipt(tender);
    if (rebalance && !_isBalancingTender) {
      _rebalanceFromTender(index);
    }
  }

  void _clearMismatchedCardReceipt(_TenderLineInput tender) {
    final receipt = tender.cardReceipt;
    if (receipt == null) {
      return;
    }
    final amount = _calculator.parseAmount(tender.amountController.text);
    if (tender.method != PaymentMethod.card || !receipt.amountMatches(amount)) {
      tender.cardReceipt = null;
    }
  }

  String _normalizedAmountText(String value) {
    final decimalIndex = value.indexOf('.');
    if (decimalIndex == -1) {
      return value;
    }
    final whole = value.substring(0, decimalIndex + 1);
    final decimals = value.substring(decimalIndex + 1);
    return '$whole${decimals.substring(0, math.min(2, decimals.length))}';
  }

  List<PaymentMethod> get _enabledMethods {
    return [
      if (widget.enableCashPayments) PaymentMethod.cash,
      if (widget.enableCardPayments) PaymentMethod.card,
      if (widget.enableTransferPayments) PaymentMethod.transfer,
    ];
  }

  List<SplitTenderInput> get _tenderInputs {
    return [
      for (final tender in _tenders)
        SplitTenderInput(
          method: tender.method,
          amount: _calculator.parseAmount(tender.amountController.text),
          cardReceipt: tender.cardReceipt,
        ),
    ];
  }

  SplitTenderPaymentSummary get _summary {
    return _calculator.summary(total: widget.total, tenders: _tenderInputs);
  }

  List<SaleCheckoutPaymentDraft>? get _appliedPayments {
    return _calculator.appliedPayments(
      total: widget.total,
      tenders: _tenderInputs,
    );
  }

  bool get _canSubmit =>
      _enabledMethods.isNotEmpty &&
      _appliedPayments != null &&
      !_hasMissingRequiredCardReceipt;

  bool get _hasMissingRequiredCardReceipt {
    if (!widget.requireCardReceipt) {
      return false;
    }
    return _tenders.any((tender) {
      return tender.method == PaymentMethod.card &&
          _calculator.parseAmount(tender.amountController.text) > 0 &&
          tender.cardReceipt == null;
    });
  }

  bool get _canUseSplitTenderMode => _enabledMethods.length > 1;

  bool get _isSplitTenderMode => _tenders.length > 1;

  _TenderLineInput? get _activeTender {
    if (_activeTenderIndex < 0 || _activeTenderIndex >= _tenders.length) {
      return null;
    }
    return _tenders[_activeTenderIndex];
  }

  PaymentMethod get _nextTenderMethod {
    final usedMethods = _tenders.map((tender) => tender.method).toSet();
    for (final method in _enabledMethods) {
      if (!usedMethods.contains(method)) {
        return method;
      }
    }
    return _enabledMethods.first;
  }

  List<double> get _quickAmounts {
    final total = widget.total;
    final roundedToFive = (total / 5).ceil() * 5;
    final roundedToTen = (total / 10).ceil() * 10;
    final candidates = <double>[total, roundedToFive.toDouble()];
    if (roundedToTen > roundedToFive) {
      candidates.add(roundedToTen.toDouble());
    }
    candidates.addAll([20.0, 50.0, 100.0].where((amount) => amount > total));
    return candidates.toSet().take(4).toList(growable: false);
  }
}

class _PaymentHeader extends StatelessWidget {
  const _PaymentHeader({required this.title, required this.onCancel});

  final String title;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.sm,
        spacing.sm,
      ),
      child: Row(
        children: [
          const Icon(Icons.payments_outlined),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context)!.cancelButton,
            onPressed: onCancel,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _TenderLineInput {
  _TenderLineInput({required this.method, required String amount})
    : amountController = TextEditingController(text: amount);

  PaymentMethod method;
  final TextEditingController amountController;
  CardPaymentReceipt? cardReceipt;

  void dispose() {
    amountController.dispose();
  }
}
