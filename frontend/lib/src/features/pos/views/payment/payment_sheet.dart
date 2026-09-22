import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/card_payment_receipt.dart';
import '../../../../data/models/money_position.dart';
import '../../../../data/models/sale_order.dart';
import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../companion/companion_scan_listener.dart';
import '../../../companion/companion_scope.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../../../shared/tutor/anchors.dart';
import '../../../../shared/tutor/tutor_target.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/payments/bank_account_picker.dart';
import '../../models/split_tender_payment.dart';
import 'card_receipt_validation_dialog.dart';
import 'payment_method_segmented_control.dart';
import 'pointy_amount_display.dart';
import 'pointy_keypad.dart';
import 'quick_amount_bar.dart';
import 'receipt_toggle_row.dart';
import 'sale_type_segmented_control.dart';
import 'tender_line_editor.dart';

class PaymentSheetResult {
  const PaymentSheetResult({
    required this.payments,
    required this.shareInvoiceAfterPayment,
    this.saleType = SaleType.standard,
    this.validUntil,
    this.dueDate,
    this.reserveStock = false,
    this.printProof = false,
  });

  final List<SaleCheckoutPaymentDraft> payments;
  final bool shareInvoiceAfterPayment;

  /// How the sale is recorded (standard / credit / quotation).
  final SaleType saleType;

  /// Quotation expiry / stock-hold deadline; null when not a held quotation.
  final DateTime? validUntil;

  /// Credit-only: when the debt falls due. Null means the cashier cleared it —
  /// an open tab — and is passed through as such rather than as "unset".
  final DateTime? dueDate;

  /// Quotation-only: hold the quoted quantities until [validUntil].
  final bool reserveStock;

  /// Credit-only: print a down-payment proof (سند قبض) after checkout.
  final bool printProof;
}

Future<PaymentSheetResult?> showPosPaymentSheet({
  required BuildContext context,
  required double total,
  required bool enableCashPayments,
  required bool enableCardPayments,
  required bool enableTransferPayments,
  required bool requireCardReceipt,
  required List<String> trustedCardTerminalIds,
  List<MoneyAccount> bankAccounts = const [],
  MoneyAccount? Function(String terminalId)? accountForTerminal,
  required bool showPrintInvoiceToggle,
  required bool printInvoiceAfterPayment,
  required ValueChanged<bool> onPrintInvoiceChanged,
  required bool showShareInvoiceToggle,
  required bool shareInvoiceAfterPayment,
  required ValueChanged<bool> onShareInvoiceChanged,
  bool hasCustomer = false,
  bool requireCustomerForCredit = false,
  bool enableQuotations = true,
  bool enableCredit = true,
  DateTime? proposedDueDate,
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
      bankAccounts: bankAccounts,
      accountForTerminal: accountForTerminal,
      showPrintInvoiceToggle: showPrintInvoiceToggle,
      printInvoiceAfterPayment: printInvoiceAfterPayment,
      onPrintInvoiceChanged: onPrintInvoiceChanged,
      showShareInvoiceToggle: showShareInvoiceToggle,
      shareInvoiceAfterPayment: shareInvoiceAfterPayment,
      onShareInvoiceChanged: onShareInvoiceChanged,
      hasCustomer: hasCustomer,
      requireCustomerForCredit: requireCustomerForCredit,
      enableQuotations: enableQuotations,
      enableCredit: enableCredit,
      proposedDueDate: proposedDueDate,
      onCancel: () => Navigator.of(modalContext).pop(),
      onSubmit: (result) => Navigator.of(modalContext).pop(result),
    );
  }

  return showAdaptiveFormSurface<PaymentSheetResult>(
    context: context,
    size: AdaptiveModalSize.expanded,
    desktopBreakpoint: AppBreakpoints.tabletMin,
    maxWidth: width < AppBreakpoints.tabletMin ? null : 1120,
    maxHeightFactor: width < AppBreakpoints.tabletMin ? 1 : 0.98,
    builder: childBuilder,
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
    this.bankAccounts = const [],
    this.accountForTerminal,
    required this.showPrintInvoiceToggle,
    required this.printInvoiceAfterPayment,
    required this.onPrintInvoiceChanged,
    required this.showShareInvoiceToggle,
    required this.shareInvoiceAfterPayment,
    required this.onShareInvoiceChanged,
    required this.onSubmit,
    required this.onCancel,
    this.hasCustomer = false,
    this.requireCustomerForCredit = false,
    this.enableQuotations = true,
    this.enableCredit = true,
    this.proposedDueDate,
    @visibleForTesting this.clock = DateTime.now,
  });

  final double total;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardReceipt;
  final List<String> trustedCardTerminalIds;

  /// The shop's active bank accounts. Empty — the default — hides the account
  /// control entirely and checkout is exactly what it was.
  final List<MoneyAccount> bankAccounts;

  /// Which account a slip from this terminal belongs to. Null when the shop
  /// has mapped no terminals, in which case a scanned receipt still attaches
  /// to its payment; it just does not choose a bank.
  final MoneyAccount? Function(String terminalId)? accountForTerminal;
  final bool showPrintInvoiceToggle;
  final bool printInvoiceAfterPayment;
  final ValueChanged<bool> onPrintInvoiceChanged;
  final bool showShareInvoiceToggle;
  final bool shareInvoiceAfterPayment;
  final ValueChanged<bool> onShareInvoiceChanged;
  final ValueChanged<PaymentSheetResult> onSubmit;
  final VoidCallback onCancel;

  /// Whether a customer is attached to the cart. Used to gate credit/quotation
  /// confirmation when [requireCustomerForCredit] is on.
  final bool hasCustomer;

  /// Mirrors the shop setting: a credit or quotation sale needs a customer.
  final bool requireCustomerForCredit;

  /// Whether the عرض سعر (quotation) sale type is offered.
  final bool enableQuotations;

  /// Whether the آجل (credit) sale type is offered.
  final bool enableCredit;

  /// The due date the customer's (or the shop's) agreed terms produce for a
  /// sale rung up today, resolved server-side. Seeds the credit picker so the
  /// common case is one tap, and stays overridable. Null means no terms are
  /// configured, which is the same as an open tab.
  final DateTime? proposedDueDate;

  /// Injectable time source so tests can drive scanner-burst timing.
  final DateTime Function() clock;

  @override
  State<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  static const _calculator = SplitTenderPaymentCalculator();
  static const _receiptMatcher = CardReceiptMatcher();

  /// Two keys closer together than this were not typed by a person.
  static const _scanBurstGap = Duration(milliseconds: 80);

  final List<_TenderLineInput> _tenders = [];
  var _activeTenderIndex = 0;
  var _showPaymentError = false;
  var _isBalancingTender = false;
  var _saleType = SaleType.standard;
  var _reserveStock = false;
  var _printProof = false;
  DateTime? _validUntil;
  // Seeded from the customer's (or the shop's) terms the first time the credit
  // type is chosen, then owned by the cashier. Kept apart from _validUntil
  // because a quotation's expiry and a debt's due date are different promises.
  DateTime? _dueDate;
  late var _printInvoiceAfterPayment = widget.printInvoiceAfterPayment;
  late var _shareInvoiceAfterPayment = widget.shareInvoiceAfterPayment;

  /// A receipt that passed every check but has no payment line to prove yet —
  /// scanned before the cashier set the tender up, or released by a line that
  /// stopped matching it. It attaches itself the moment a card payment of its
  /// amount exists, so a good receipt is never silently thrown away.
  CardPaymentReceipt? _pendingCardReceipt;

  /// Why the last scanned receipt was refused; null when nothing was refused.
  String? _scanError;

  // How fast the keys reaching this sheet are arriving. A wedge scanner types
  // a whole receipt URL in about a second, and that URL is full of digits —
  // without this, every scan would fire the 1/2/3 method hotkeys dozens of
  // times (each one rewriting the tender) and its terminating Enter could
  // confirm the sale outright.
  DateTime? _lastKeyDownAt;
  var _fastKeyRun = 0;

  bool get _isCredit => _saleType == SaleType.credit;
  bool get _isQuotation => _saleType == SaleType.quotation;

  /// A credit or quotation sale needs a customer when the shop requires one;
  /// confirming is blocked until one is attached to the cart.
  bool get _isMissingRequiredCustomer =>
      widget.requireCustomerForCredit &&
      !widget.hasCustomer &&
      (_isCredit || _isQuotation);

  @override
  void initState() {
    super.initState();
    final methods = _enabledMethods;
    if (methods.isNotEmpty) {
      _tenders.add(
        _TenderLineInput(
          method: methods.first,
          amount: widget.total.toStringAsFixed(2),
          moneyAccountId: _defaultBankAccountId,
        ),
      );
    }
  }

  /// The account a new tender starts on. Null whenever the control would not
  /// be shown, so a shop that has configured nothing sends nothing.
  int? get _defaultBankAccountId =>
      BankAccountPicker.initialSelection(widget.bankAccounts);

  @override
  void dispose() {
    for (final tender in _tenders) {
      tender.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The terminal slip is scanned straight into the sheet — by the counter
    // scanner or a paired phone — and matches the card payment on its own. The
    // cashier used to have to open the match dialog first, which is one dialog
    // too many for something the till can recognise by itself.
    return CompanionScanListener(
      bridge: CompanionScope.bridgeOf(context),
      onScan: _handleScannedValue,
      child: BarcodeScanListener(
        // Deliberately the default (short) burst length rather than a
        // receipt-sized one: only a receipt link is acted on, but every burst
        // has to be caught and rolled back, because the field it would
        // otherwise land in is a payment amount.
        clock: widget.clock,
        onBarcodeScanned: _handleScannedValue,
        child: _buildSheet(),
      ),
    );
  }

  Widget _buildSheet() {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final summary = _summary;

    // Keyboard-first checkout: Ctrl+1/2/3 pick cash/card/transfer, Enter
    // confirms, Esc cancels.
    //
    // The method keys carry Ctrl because the bare digits did not work: a
    // `CallbackShortcuts` ancestor sees a digit that the focused text field did
    // not treat as a shortcut, so typing an amount into a tender line selected
    // a payment method instead of entering the number. Unreachable on a sale
    // paid one way — the amount is already filled in — and unavoidable on a
    // split, where typing the first tender's amount is the whole operation.
    //
    // Ctrl also settles the scanner question by construction: a wedge cannot
    // hold a modifier, so a scanned receipt link can no longer look like a
    // method key.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
        const SingleActivator(LogicalKeyboardKey.enter): _submitIfPossible,
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            _submitIfPossible,
        for (final (method, digit, numpad) in const [
          (
            PaymentMethod.cash,
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.numpad1,
          ),
          (
            PaymentMethod.card,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.numpad2,
          ),
          (
            PaymentMethod.transfer,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.numpad3,
          ),
        ]) ...{
          SingleActivator(digit, control: true): () =>
              _selectMethodByHotkey(method),
          SingleActivator(numpad, control: true): () =>
              _selectMethodByHotkey(method),
          // macOS cashiers reach for ⌘ without thinking; both work.
          SingleActivator(digit, meta: true): () =>
              _selectMethodByHotkey(method),
          SingleActivator(numpad, meta: true): () =>
              _selectMethodByHotkey(method),
        },
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _noteKeyTiming,
        child: TutorTarget(
          anchor: TutorAnchor.paymentSheet,
          child: Material(
            key: const ValueKey('payment_sheet'),
            color: colors.surface,
            borderRadius: BorderRadius.circular(PointyRadii.sheet),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PaymentHeader(
                    title: l10n.paymentDialogTitle,
                    onCancel: widget.onCancel,
                  ),
                  Divider(height: 1, color: colors.line),
                  Flexible(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide =
                            constraints.maxWidth >= AppBreakpoints.tabletMin;
                        return SingleChildScrollView(
                          padding: spacing.sectionPadding,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SaleTypeSegmentedControl(
                                label: l10n.saleTypeLabel,
                                selectedSaleType: _saleType,
                                enableCredit: widget.enableCredit,
                                enableQuotations: widget.enableQuotations,
                                onSelected: _selectSaleType,
                              ),
                              if (_saleTypeSelectorVisible)
                                SizedBox(height: spacing.lg),
                              if (_isMissingRequiredCustomer) ...[
                                PointyInlineMessage.warning(
                                  key: const ValueKey(
                                    'sale_customer_required_banner',
                                  ),
                                  message: l10n.saleCustomerRequiredBanner,
                                  icon: Icons.person_off_outlined,
                                ),
                                SizedBox(height: spacing.lg),
                              ],
                              if (_isQuotation)
                                _buildQuotationPanel(l10n)
                              else if (isWide)
                                _buildWidePaymentLayout(l10n, summary)
                              else
                                _buildNarrowPaymentLayout(l10n, summary),
                            ],
                          ),
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
                    primaryAction: TutorTarget(
                      anchor: TutorAnchor.paymentConfirmButton,
                      child: FilledButton.icon(
                        key: const ValueKey('payment_confirm_button'),
                        onPressed: _canSubmit ? _submit : null,
                        icon: const Icon(Icons.check),
                        label: Text(l10n.confirmPaymentButton),
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

  /// Watches how fast keys are arriving so the sheet's single-key shortcuts
  /// can tell a cashier from a scanner. Never consumes anything.
  KeyEventResult _noteKeyTiming(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final now = widget.clock();
      final previous = _lastKeyDownAt;
      _lastKeyDownAt = now;
      _fastKeyRun =
          previous != null && now.difference(previous) <= _scanBurstGap
          ? _fastKeyRun + 1
          : 0;
    }
    return KeyEventResult.ignored;
  }

  /// True while keys are arriving faster than fingers can produce them: four
  /// of them inside a quarter of a second is a wedge scanner typing a barcode,
  /// not a cashier reaching for a shortcut. The sheet's one-key shortcuts step
  /// aside for the length of that burst — a scan must never pick a payment
  /// method, and its terminating Enter must never confirm the sale.
  bool get _isScannerTyping => _fastKeyRun >= 3;

  void _submitIfPossible() {
    if (_isScannerTyping) {
      return;
    }
    if (_canSubmit) {
      _submit();
    }
  }

  void _selectMethodByHotkey(PaymentMethod method) {
    // A quotation takes no payment, and a credit sale enters its down-payment
    // per line, so the single-method hotkeys are inert for both.
    //
    // No scanner check here, unlike Enter: these keys carry Ctrl, and a wedge
    // cannot hold a modifier. Keeping the check would have made the shortcut
    // fail precisely when it is most useful — pressed straight after typing an
    // amount, which reads to the burst guard as a scan in progress.
    if (_isQuotation || _isCredit) {
      return;
    }
    if (_enabledMethods.contains(method)) {
      _selectSinglePaymentMethod(method);
    }
  }

  /// True when more than one sale type is offered (so the selector renders).
  bool get _saleTypeSelectorVisible =>
      widget.enableCredit || widget.enableQuotations;

  void _selectSaleType(SaleType saleType) {
    if (saleType == _saleType) {
      return;
    }
    setState(() {
      _saleType = saleType;
      _showPaymentError = false;
      _scanError = null;
      _pendingCardReceipt = null;
      _reserveStock = saleType == SaleType.quotation && _reserveStock;
      _validUntil = null;
      // Propose the agreed term the moment آجل is chosen, so the cashier sees
      // the date the shop will actually chase — and can still overrule it.
      _dueDate = saleType == SaleType.credit ? widget.proposedDueDate : null;
      if (saleType == SaleType.standard) {
        // Paid-in-full sale: a single tender covering the whole total.
        _resetToFullPaymentTender();
      } else {
        // Debt (آجل) and quotation start with NO payment line: a debt is fully
        // on the customer's account until the cashier adds a down-payment, and a
        // quotation takes no payment at all. This also lets the cashier leave it
        // empty (fully on credit) without fighting a prefilled total.
        _clearTenders();
      }
    });
  }

  void _clearTenders() {
    for (final tender in _tenders) {
      tender.dispose();
    }
    _tenders.clear();
    _activeTenderIndex = 0;
  }

  void _resetToFullPaymentTender() {
    final methods = _enabledMethods;
    if (methods.isEmpty) {
      _clearTenders();
      return;
    }
    while (_tenders.length > 1) {
      _tenders.removeLast().dispose();
    }
    if (_tenders.isEmpty) {
      _tenders.add(
        _TenderLineInput(
          method: methods.first,
          amount: widget.total.toStringAsFixed(2),
          moneyAccountId: _defaultBankAccountId,
        ),
      );
    } else {
      _setTenderAmount(0, widget.total.toStringAsFixed(2), rebalance: false);
    }
    _activeTenderIndex = 0;
  }

  Widget _buildWidePaymentLayout(
    AppLocalizations l10n,
    SplitTenderPaymentSummary summary,
  ) {
    final spacing = AdaptiveSpacing.of(context);

    // The keypad needs a tender to type into; a credit sale with no down-payment
    // line yet has none, so the keypad column is dropped until one is added.
    final showKeypad = _activeTender != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildPaymentControls(l10n, includeKeypad: false)),
        SizedBox(width: spacing.lg),
        if (showKeypad) ...[
          SizedBox(width: 240, child: _buildKeypad(l10n)),
          SizedBox(width: spacing.lg),
        ],
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

    final colors = context.pointyColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The single-method quick selector sets the tender to the full total, so
        // it's only for paid-in-full (standard) sales. A credit down-payment is
        // entered per line; showing it for credit would overwrite the amount.
        if (!_isCredit && activeTender != null) ...[
          PaymentMethodSegmentedControl(
            label: l10n.paymentMethodLabel,
            enabledMethods: _enabledMethods,
            selectedMethod: activeTender.method,
            onSelected: _selectSinglePaymentMethod,
          ),
          SizedBox(height: spacing.md),
        ],
        if (activeTender?.method == PaymentMethod.cash) ...[
          QuickAmountBar(
            label: l10n.paymentQuickAmountsLabel,
            amounts: _quickAmounts,
            onSelected: (amount) =>
                _setTenderAmount(_activeTenderIndex, amount.toStringAsFixed(2)),
          ),
          SizedBox(height: spacing.md),
        ],
        if (includeKeypad && activeTender != null) ...[
          _buildKeypad(l10n),
          SizedBox(height: spacing.md),
        ],
        // Credit (آجل): make it explicit that the sale is on the customer's
        // account and anything entered is only a down-payment.
        if (_isCredit) ...[
          Text(
            _tenders.isEmpty
                ? l10n.creditFullyOnAccountHint
                : l10n.creditDownPaymentHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          SizedBox(height: spacing.md),
        ],
        ..._buildScanNotice(l10n, spacing),
        for (final entry in _tenders.indexed) ...[
          if (entry.$1 > 0) SizedBox(height: spacing.sm),
          TenderLineEditor(
            index: entry.$1,
            title: _isCredit
                ? l10n.creditDownPaymentTenderTitle
                : l10n.paymentTenderLineTitle(entry.$1 + 1),
            amountLabel: l10n.paymentTenderAmountLabel,
            methodLabel: l10n.paymentMethodLabel,
            removeTooltip: l10n.removeTenderTooltip,
            amountController: entry.$2.amountController,
            method: entry.$2.method,
            enabledMethods: _enabledMethods,
            // Credit lines are always removable (down to zero = fully on
            // credit); standard sales keep at least one paying line.
            canRemove: _isCredit || _tenders.length > 1,
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
            bankAccounts: widget.bankAccounts,
            moneyAccountId: entry.$2.moneyAccountId,
            autoSelectedTerminal: entry.$2.autoSelectedTerminal,
            onMoneyAccountChanged: (accountId) =>
                _updateTenderAccount(entry.$1, accountId),
          ),
        ],
        SizedBox(height: spacing.sm),
        TutorTarget(
          anchor: TutorAnchor.paymentAddTenderButton,
          child: OutlinedButton.icon(
            key: const ValueKey('payment_add_tender'),
            onPressed: _addTender,
            icon: const Icon(Icons.add),
            label: Text(
              _isCredit ? l10n.addDownPaymentButton : l10n.addSplitTenderButton,
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
        // Credit (آجل): after the optional down-payment, set when the remaining
        // balance is due. The debt-collection SMS holds off until this date.
        if (_isCredit) ...[
          SizedBox(height: spacing.md),
          _buildCreditDueDatePicker(l10n),
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
        if (widget.showShareInvoiceToggle) ...[
          SizedBox(height: spacing.sm),
          ReceiptToggleRow(
            label: l10n.shareInvoiceAfterPaymentLabel,
            subtitle: l10n.shareInvoiceToggleSubtitle,
            tooltip: l10n.shareInvoiceToggleTooltip,
            value: _shareInvoiceAfterPayment,
            onChanged: (value) {
              setState(() => _shareInvoiceAfterPayment = value);
              widget.onShareInvoiceChanged(value);
            },
          ),
        ],
        if (_isCredit) ...[
          SizedBox(height: spacing.sm),
          ReceiptToggleRow(
            label: l10n.printDownPaymentProofLabel,
            subtitle: l10n.printDownPaymentProofSubtitle,
            tooltip: l10n.printDownPaymentProofLabel,
            value: _printProof,
            onChanged: (value) => setState(() => _printProof = value),
          ),
        ],
      ],
    );
  }

  /// What the last scan did, when it needs saying.
  ///
  /// A matched receipt already says so on its own payment line, so this is
  /// only ever a problem: a receipt that could not be read, or a good one
  /// still looking for the payment it belongs to.
  List<Widget> _buildScanNotice(
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    final pending = _pendingCardReceipt;
    if (pending != null) {
      return [
        PointyInlineMessage.warning(
          key: const ValueKey('payment_scan_pending_receipt'),
          compact: true,
          // A receipt that could not state its amount cannot be described by
          // one; quoting its blank amount as "0.00" would be a lie about what
          // was scanned.
          message: pending.canProveAmount
              ? l10n.cardReceiptAwaitingCardTender(formatMoney(pending.amount))
              : l10n.cardReceiptAwaitingCardTenderUnknownAmount,
        ),
        SizedBox(height: spacing.sm),
      ];
    }
    final error = _scanError;
    if (error != null) {
      return [
        PointyInlineMessage.error(
          key: const ValueKey('payment_scan_receipt_error'),
          compact: true,
          message: error,
        ),
        SizedBox(height: spacing.sm),
      ];
    }
    return const [];
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
          key: const ValueKey('payment_remaining_display'),
          // Credit (آجل): the unpaid remainder becomes the customer's balance,
          // labelled explicitly so the cashier reads it as a debt, not change.
          label: _isCredit
              ? l10n.creditBalanceDueLabel
              : summary.changeDue > 0
              ? l10n.changeDueLabel
              : l10n.remainingAmountLabel,
          value: formatMoney(
            summary.changeDue > 0 ? summary.changeDue : summary.remaining,
          ),
          tone: summary.changeDue > 0
              ? PointyAmountDisplayTone.success
              : PointyAmountDisplayTone.warning,
        ),
        // The missing-customer blocker already shows as the top banner — don't
        // repeat the same message down here in the summary.
        if ((_showPaymentError || !_canSubmit) &&
            !_isMissingRequiredCustomer) ...[
          SizedBox(height: spacing.sm),
          Text(
            _summaryErrorMessage(l10n),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: context.pointyColors.danger),
          ),
        ],
      ],
    );
  }

  String _summaryErrorMessage(AppLocalizations l10n) {
    if (_isMissingRequiredCustomer) {
      return l10n.saleCustomerRequiredBanner;
    }
    if (_enabledMethods.isEmpty) {
      return l10n.noEnabledPaymentMethods;
    }
    if (_hasMissingRequiredCardReceipt) {
      return l10n.cardReceiptRequiredError;
    }
    // Credit accepts a partial down-payment, so the only blocker left is an
    // over-tender the cash can't make change for.
    return _isCredit
        ? l10n.creditDownPaymentTooHighError
        : l10n.paymentTotalTooLowError;
  }

  /// Quotation (عرض سعر) takes no payment: the cashier only decides whether to
  /// hold the quoted stock and, if so, until when.
  Widget _buildQuotationPanel(AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PointyAmountDisplay(
          key: const ValueKey('payment_amount_display'),
          label: l10n.quotationTotalLabel,
          value: formatMoney(widget.total),
          tone: PointyAmountDisplayTone.primary,
          emphasized: true,
        ),
        SizedBox(height: spacing.md),
        ReceiptToggleRow(
          key: const ValueKey('quotation_reserve_stock_toggle'),
          label: l10n.quotationReserveStockLabel,
          subtitle: l10n.quotationReserveStockSubtitle,
          tooltip: l10n.quotationReserveStockLabel,
          value: _reserveStock,
          onChanged: (value) => setState(() {
            _reserveStock = value;
            if (value && _validUntil == null) {
              _validUntil = _defaultValidUntil();
            }
          }),
        ),
        if (_reserveStock) ...[
          SizedBox(height: spacing.sm),
          InkWell(
            key: const ValueKey('quotation_valid_until_picker'),
            onTap: _pickValidUntil,
            borderRadius: BorderRadius.circular(8),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: l10n.quotationValidUntilLabel,
                prefixIcon: const Icon(Icons.event_outlined),
                suffixIcon: const Icon(Icons.expand_more),
              ),
              child: Text(
                _validUntil == null
                    ? l10n.quotationValidUntilUnset
                    : _formatDate(_validUntil!),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
        ],
        SizedBox(height: spacing.md),
        Text(
          l10n.quotationNoPaymentHint,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ],
    );
  }

  DateTime _defaultValidUntil() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).add(const Duration(days: 7));
  }

  Future<void> _pickValidUntil() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = _validUntil ?? _defaultValidUntil();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(today) ? today : initial,
      firstDate: today,
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(
      () => _validUntil = DateTime(picked.year, picked.month, picked.day),
    );
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Falls back to the proposed term, then to today: opening the picker on a
    // date the shop would not have chosen is a worse default than opening it
    // on the one it did.
    final initial = _dueDate ?? widget.proposedDueDate ?? today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(today) ? today : initial,
      // The backend refuses a due date before the invoice date, so the picker
      // must not offer one.
      firstDate: today,
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _dueDate = DateTime(picked.year, picked.month, picked.day));
  }

  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  /// Credit (آجل): an optional due date for the debt. The debt-collection SMS
  /// holds off until it arrives; leaving it unset means the balance is due now.
  /// Quick chips make the common terms one tap; the field opens a full calendar.
  Widget _buildCreditDueDatePicker(AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    final hasDate = _dueDate != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          key: const ValueKey('credit_due_date_picker'),
          onTap: _pickDueDate,
          borderRadius: BorderRadius.circular(8),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: l10n.creditDueDateLabel,
              prefixIcon: const Icon(Icons.event_available_outlined),
              suffixIcon: hasDate
                  // Only present once a date is set, which is what makes it the
                  // honest thing for a lesson to check after picking one.
                  ? TutorTarget(
                      anchor: TutorAnchor.paymentCreditDueDateClear,
                      child: IconButton(
                        key: const ValueKey('credit_due_date_clear'),
                        tooltip: l10n.creditDueDateClearTooltip,
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _dueDate = null),
                      ),
                    )
                  : const Icon(Icons.expand_more),
            ),
            child: Text(
              hasDate ? _formatDate(_dueDate!) : l10n.creditDueDateUnset,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ),
        SizedBox(height: spacing.sm),
        Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.sm,
          children: [
            _dueDatePresetChip(l10n.creditDueDatePresetWeek, 7),
            _dueDatePresetChip(l10n.creditDueDatePresetTwoWeeks, 14),
            _dueDatePresetChip(l10n.creditDueDatePresetMonth, 30),
          ],
        ),
      ],
    );
  }

  Widget _dueDatePresetChip(String label, int days) {
    final now = DateTime.now();
    final target = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(Duration(days: days));
    final selected = _dueDate != null && DateUtils.isSameDay(_dueDate, target);
    return TutorTarget(
      anchor: TutorAnchor.paymentCreditDueDatePreset,
      id: '$days',
      child: ChoiceChip(
        key: ValueKey('credit_due_date_preset_$days'),
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _dueDate = target),
      ),
    );
  }

  void _submit() {
    final payments = _appliedPayments;
    if (payments == null ||
        _hasMissingRequiredCardReceipt ||
        _isMissingRequiredCustomer) {
      setState(() => _showPaymentError = true);
      return;
    }
    widget.onSubmit(
      PaymentSheetResult(
        payments: payments,
        shareInvoiceAfterPayment: _shareInvoiceAfterPayment,
        saleType: _saleType,
        // A quotation carries a stock-hold deadline only when it actually
        // holds stock; a credit invoice carries its own, separate due date.
        validUntil: _isQuotation && _reserveStock ? _validUntil : null,
        dueDate: _isCredit ? _dueDate : null,
        reserveStock: _isQuotation && _reserveStock,
        printProof: _isCredit && _printProof,
      ),
    );
  }

  /// A receipt scanned into the sheet, from the counter scanner or a paired
  /// phone, matched without the cashier opening anything.
  ///
  /// The checks are the match dialog's, to the letter — the payload decodes
  /// into a successful receipt from a terminal the shop owns, for the amount
  /// of the payment it is attached to — so nothing is accepted here that would
  /// have been refused there. Everything else a till gets scanned with is left
  /// alone: a product barcode must never become a payment decision.
  void _handleScannedValue(String value) {
    if (_isQuotation || !_receiptMatcher.isReceiptLink(value)) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final CardPaymentReceipt receipt;
    try {
      receipt = _receiptMatcher.verify(
        value,
        trustedTerminalIds: widget.trustedCardTerminalIds,
      );
    } on CardPaymentReceiptException catch (exception) {
      ScanFeedbackSounds.instance.play(ScanFeedback.error);
      setState(() {
        _pendingCardReceipt = null;
        _scanError = cardReceiptErrorMessage(l10n, exception);
      });
      return;
    }

    setState(() {
      _scanError = null;
      // One terminal slip proves one payment. A rescan — an impatient second
      // trigger, or the phone and the counter scanner both reporting the same
      // QR — must not be spent a second time on another card line.
      if (_isAlreadyMatched(receipt)) {
        _pendingCardReceipt = null;
        return;
      }
      _pendingCardReceipt = receipt;
      _placePendingCardReceipt();
    });
    ScanFeedbackSounds.instance.play(
      _pendingCardReceipt == null
          ? ScanFeedback.success
          : ScanFeedback.notFound,
    );
  }

  bool _isAlreadyMatched(CardPaymentReceipt receipt) {
    return _tenders.any(
      (tender) => tender.cardReceipt?.sourceUrl == receipt.sourceUrl,
    );
  }

  /// Hands a held receipt to the first payment it can stand for: a card line
  /// of exactly its amount that has no receipt of its own.
  ///
  /// It never changes what the cashier entered. A receipt with nowhere to go
  /// waits instead — the sheet says so, and the cashier setting that payment
  /// up completes the match without scanning again.
  void _placePendingCardReceipt() {
    final receipt = _pendingCardReceipt;
    if (receipt == null) {
      return;
    }
    for (final tender in _tenders) {
      if (tender.method != PaymentMethod.card || tender.cardReceipt != null) {
        continue;
      }
      final amount = _calculator.parseAmount(tender.amountController.text);
      if (amount <= 0) {
        continue;
      }
      // A receipt that can state its amount must land on the line that matches
      // it. One that cannot — its details live on the issuer's server — goes to
      // the first card line still without a slip, because there is nothing to
      // match on and leaving it unattached would lose the only proof the sale
      // has. The backend checks it against this line's amount once the issuer
      // answers.
      if (receipt.canProveAmount && !receipt.amountMatches(amount)) {
        continue;
      }
      tender.cardReceipt = receipt;
      _applyTerminalAccount(tender, receipt);
      _pendingCardReceipt = null;
      _scanError = null;
      _showPaymentError = false;
      return;
    }
  }

  /// Takes a receipt back off a payment line that no longer fits it, and holds
  /// on to it rather than dropping it.
  ///
  /// A cashier correcting a typed amount (45 on the way to 450) or switching a
  /// line to cash for a moment should not have to walk back to the terminal
  /// and scan the slip again — it is still a valid receipt, still unspent, and
  /// re-attaches by itself as soon as a payment fits it again.
  void _releaseCardReceipt(_TenderLineInput tender) {
    final receipt = tender.cardReceipt;
    if (receipt == null) {
      return;
    }
    tender.cardReceipt = null;
    // The account the slip chose goes back with it. Keeping it would leave a
    // line claiming a bank on the authority of a receipt it no longer holds.
    if (tender.autoSelectedTerminal != null) {
      tender.moneyAccountId = _defaultBankAccountId;
      tender.autoSelectedTerminal = null;
    }
    _pendingCardReceipt = receipt;
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
      _applyTerminalAccount(tender, receipt);
      _activeTenderIndex = index;
      _showPaymentError = false;
      _scanError = null;
      if (_pendingCardReceipt?.sourceUrl == receipt.sourceUrl) {
        _pendingCardReceipt = null;
      }
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
          // A credit down-payment starts blank (the cashier types what was
          // actually paid); a standard split tender prefills the amount still
          // needed to cover the total.
          amount: _isCredit
              ? ''
              : (summary.remaining > 0
                    ? summary.remaining.toStringAsFixed(2)
                    : ''),
          moneyAccountId: _defaultBankAccountId,
        ),
      );
      _activeTenderIndex = _tenders.length - 1;
      _showPaymentError = false;
      _placePendingCardReceipt();
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
      _placePendingCardReceipt();
    });
  }

  void _rebalanceAfterTenderRemoval() {
    if (_isCredit || _tenders.isEmpty) {
      // Credit down-payments stand alone — removing one line must never inflate
      // a surviving line to cover the total (mirrors _rebalanceFromTender).
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
    if (editedIndex >= 0 && editedIndex < _tenders.length) {
      // Typing straight into the amount field reaches the tender through here
      // and nowhere else, so this is where an amount edited after the fact
      // stops fitting the receipt matched to it. The slip is taken back rather
      // than left proving a payment it was never rung up for.
      _clearMismatchedCardReceipt(_tenders[editedIndex]);
      _placePendingCardReceipt();
    }
    if (_isCredit) {
      // Credit down-payments don't need to cover the total, so each line stands
      // alone — never auto-balance a sibling line to fill the remainder.
      setState(() {
        _activeTenderIndex = editedIndex;
        _showPaymentError = false;
      });
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

  /// The cashier naming the bank themselves. Drops the "chosen by terminal X"
  /// note: once a person has overruled the mapping, saying the till decided
  /// would be a claim about this payment that is no longer true.
  void _updateTenderAccount(int index, int? accountId) {
    setState(() {
      final tender = _tenders[index];
      tender.moneyAccountId = accountId;
      tender.autoSelectedTerminal = null;
      _activeTenderIndex = index;
    });
  }

  /// Point a payment line at the account the machine that printed its slip
  /// settles into.
  ///
  /// Only ever fills a line the cashier has not already decided for
  /// themselves — except when the line is still sitting on the account it was
  /// merely *seeded* with, which nobody chose. That distinction is the whole
  /// behaviour: the shop mapped its terminals precisely so this would not have
  /// to be done by hand, and a cashier who did reach for the dropdown must not
  /// have their answer overwritten by the next scan.
  void _applyTerminalAccount(
    _TenderLineInput tender,
    CardPaymentReceipt receipt,
  ) {
    final resolve = widget.accountForTerminal;
    if (resolve == null || receipt.terminalId.isEmpty) {
      return;
    }
    if (tender.moneyAccountId != null &&
        tender.moneyAccountId != _defaultBankAccountId &&
        tender.autoSelectedTerminal == null) {
      return;
    }
    final account = resolve(receipt.terminalId);
    if (account == null) {
      return;
    }
    tender.moneyAccountId = account.id;
    tender.autoSelectedTerminal = receipt.terminalId;
  }

  void _updateTenderMethod(int index, PaymentMethod method) {
    setState(() {
      _tenders[index].method = method;
      if (method != PaymentMethod.card) {
        _releaseCardReceipt(_tenders[index]);
      }
      _activeTenderIndex = index;
      _showPaymentError = false;
      // Choosing card is often the step a scanned receipt was waiting for.
      _placePendingCardReceipt();
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
        _releaseCardReceipt(tender);
      }
      _activeTenderIndex = 0;
      _showPaymentError = false;
      _setTenderAmount(0, widget.total.toStringAsFixed(2), rebalance: false);
    });
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
    _placePendingCardReceipt();
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
    if (tender.method != PaymentMethod.card) {
      _releaseCardReceipt(tender);
      return;
    }
    // A receipt that cannot state its amount can never "mismatch" one, so it
    // stays put while the cashier edits the figure. Releasing it on every
    // keystroke would detach the sale's only proof and never re-attach it.
    if (receipt.canProveAmount && !receipt.amountMatches(amount)) {
      _releaseCardReceipt(tender);
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
          moneyAccountId: tender.moneyAccountId,
        ),
    ];
  }

  SplitTenderPaymentSummary get _summary {
    return _calculator.summary(total: widget.total, tenders: _tenderInputs);
  }

  List<SaleCheckoutPaymentDraft>? get _appliedPayments {
    // A quotation never takes payment.
    if (_isQuotation) {
      return const [];
    }
    return _calculator.appliedPayments(
      total: widget.total,
      tenders: _tenderInputs,
      // Credit (آجل) treats the tender as a down-payment, so 0..total is fine.
      allowPartial: _isCredit,
    );
  }

  bool get _canSubmit {
    if (_isMissingRequiredCustomer) {
      return false;
    }
    if (_isQuotation) {
      // No tender to validate; just optionally a stock-hold deadline.
      return true;
    }
    return _enabledMethods.isNotEmpty &&
        _appliedPayments != null &&
        !_hasMissingRequiredCardReceipt;
  }

  bool get _hasMissingRequiredCardReceipt {
    if (!widget.requireCardReceipt || _isQuotation) {
      return false;
    }
    return _tenders.any((tender) {
      return tender.method == PaymentMethod.card &&
          _calculator.parseAmount(tender.amountController.text) > 0 &&
          tender.cardReceipt == null;
    });
  }

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
  _TenderLineInput({
    required this.method,
    required String amount,
    this.moneyAccountId,
  }) : amountController = TextEditingController(text: amount);

  PaymentMethod method;
  final TextEditingController amountController;
  CardPaymentReceipt? cardReceipt;

  /// The bank account this tender lands in. Null means "not said", which the
  /// server routes the way it always did.
  int? moneyAccountId;

  /// The terminal whose slip chose [moneyAccountId], when one did. Cleared the
  /// moment the cashier picks an account themselves — the note must never claim
  /// the till decided something a person overruled.
  String? autoSelectedTerminal;

  void dispose() {
    amountController.dispose();
  }
}
