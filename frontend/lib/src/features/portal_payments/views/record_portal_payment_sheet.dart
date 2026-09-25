import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/money_position.dart';
import '../../../data/models/portal_payment.dart';
import '../../../data/models/sale_order.dart' show PaymentMethod;
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payment_labels.dart';
import '../../../shared/payments/bank_account_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../../pos/views/payment/card_receipt_validation_dialog.dart';
import '../../treasury/view_models/bank_routing.dart';
import 'portal_payment_presentation.dart';
import 'portal_payment_session_picker.dart';

/// What the sheet did: an invoice recorded, or a waiting sale settled.
class PortalPaymentSheetOutcome {
  const PortalPaymentSheetOutcome({required this.order, this.linked = false});

  final PortalPaymentOrder order;
  final bool linked;
}

Future<PortalPaymentSheetOutcome?> showRecordPortalPaymentSheet(
  BuildContext context, {
  required PortalPayment payment,
  required PortalPaymentsDay day,
  required String providerName,
  required Future<Result<PortalPaymentOrder>> Function(
    PortalPaymentRecordDraft draft,
  )
  onRecord,
  required Future<Result<PortalPaymentOrder>> Function(
    PortalPaymentCandidate candidate,
  )
  onLink,
  Future<Customer?> Function(BuildContext context)? pickCustomer,
  Future<List<String>> Function()? loadTrustedTerminalIds,
}) {
  final bankAccounts = BankRoutingScope.accountsOf(context);
  return showAdaptiveModalBottomSheet<PortalPaymentSheetOutcome>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.94,
    builder: (_) => RecordPortalPaymentSheet(
      payment: payment,
      day: day,
      providerName: providerName,
      onRecord: onRecord,
      onLink: onLink,
      pickCustomer: pickCustomer,
      loadTrustedTerminalIds: loadTrustedTerminalIds,
      bankAccounts: bankAccounts,
    ),
  );
}

/// Records one website payment as the invoice the till could not issue.
///
/// Asks exactly what the checkout will: which drawer took the money, whether
/// the customer paid now or owes it (آجل), how they paid, and — where the shop
/// requires it — the card slip. The total is not asked: it is the till's own
/// price for the amount, and the server refuses a different one.
class RecordPortalPaymentSheet extends StatefulWidget {
  const RecordPortalPaymentSheet({
    super.key,
    required this.payment,
    required this.day,
    required this.providerName,
    required this.onRecord,
    required this.onLink,
    this.pickCustomer,
    this.loadTrustedTerminalIds,
    this.bankAccounts = const [],
  });

  final PortalPayment payment;
  final PortalPaymentsDay day;
  final String providerName;
  final Future<Result<PortalPaymentOrder>> Function(
    PortalPaymentRecordDraft draft,
  )
  onRecord;
  final Future<Result<PortalPaymentOrder>> Function(
    PortalPaymentCandidate candidate,
  )
  onLink;
  final Future<Customer?> Function(BuildContext context)? pickCustomer;
  final Future<List<String>> Function()? loadTrustedTerminalIds;
  final List<MoneyAccount> bankAccounts;

  @override
  State<RecordPortalPaymentSheet> createState() =>
      _RecordPortalPaymentSheetState();
}

class _RecordPortalPaymentSheetState extends State<RecordPortalPaymentSheet> {
  late int? _sessionId = PortalPaymentSessionPicker.suggestedFor(
    widget.day.sessions,
    widget.payment.paidAt,
  );
  bool _isCredit = false;
  late String _method = _methods.isEmpty ? '' : _methods.first;
  late int? _customerId = widget.payment.customerId;
  late String _customerName = widget.payment.customerId == null
      ? ''
      : widget.payment.subscriberName;
  final TextEditingController _amountPaid = TextEditingController();
  String _cardReceiptUrl = '';
  late int? _moneyAccountId = BankAccountPicker.initialSelection(
    widget.bankAccounts,
  );
  bool _differentTopUp = false;
  bool _busy = false;
  String _error = '';

  List<String> get _methods => widget.day.paymentMethods;

  double get _total => widget.payment.price ?? widget.payment.amount ?? 0;

  /// What changes hands now: all of it, or an آجل invoice's down payment.
  double? get _paidNow {
    if (!_isCredit) return _total;
    final text = _amountPaid.text.trim();
    if (text.isEmpty) return 0;
    return parseDecimal(text);
  }

  bool get _takesTender => (_paidNow ?? 0) > 0;
  bool get _isPendingSale =>
      widget.payment.state == PortalPaymentState.pendingSale;
  bool get _usesBank =>
      _method == PaymentMethod.card.apiValue ||
      _method == PaymentMethod.transfer.apiValue;

  bool get _amountPaidInvalid {
    if (!_isCredit) return false;
    final paid = _paidNow;
    return paid == null || paid < 0 || paid > _total - 0.005;
  }

  bool get _customerMissing =>
      _isCredit && widget.day.requireCustomerForCredit && _customerId == null;

  bool get _slipMissing =>
      _takesTender &&
      _method == PaymentMethod.card.apiValue &&
      widget.day.requireCardReceipt &&
      _cardReceiptUrl.isEmpty;

  bool get _canSubmit =>
      !_busy &&
      widget.payment.recordable &&
      _sessionId != null &&
      !(_isPendingSale && !_differentTopUp) &&
      !_amountPaidInvalid &&
      !_customerMissing &&
      !(_takesTender && _method.isEmpty) &&
      !_slipMissing;

  @override
  void dispose() {
    _amountPaid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsetsDirectional.fromSTEB(
                spacing.md,
                0,
                spacing.md,
                spacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.portalPaymentsRecordTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                  SizedBox(height: spacing.sm),
                  _PaymentHeader(
                    payment: widget.payment,
                    providerName: widget.providerName,
                  ),
                  if (_isPendingSale) ...[
                    SizedBox(height: spacing.md),
                    _PendingSaleSection(
                      payment: widget.payment,
                      busy: _busy,
                      differentTopUp: _differentTopUp,
                      onLink: _link,
                      onDifferentTopUp: (value) =>
                          setState(() => _differentTopUp = value),
                    ),
                  ],
                  SizedBox(height: spacing.md),
                  PointySectionHeader(title: l10n.portalPaymentsSessionLabel),
                  PortalPaymentSessionPicker(
                    sessions: widget.day.sessions,
                    paidAt: widget.payment.paidAt,
                    selectedId: _sessionId,
                    onChanged: (id) => setState(() => _sessionId = id),
                  ),
                  SizedBox(height: spacing.md),
                  PointySectionHeader(title: l10n.portalPaymentsSaleTypeLabel),
                  SegmentedButton<bool>(
                    key: const ValueKey('portal_payment_sale_type'),
                    segments: [
                      ButtonSegment(
                        value: false,
                        label: Text(l10n.portalPaymentsSaleTypePaid),
                        icon: const Icon(Icons.task_alt_outlined),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text(l10n.portalPaymentsSaleTypeCredit),
                        icon: const Icon(Icons.schedule_outlined),
                      ),
                    ],
                    selected: {_isCredit},
                    onSelectionChanged: (selection) => setState(() {
                      _isCredit = selection.first;
                      _cardReceiptUrl = '';
                    }),
                  ),
                  if (_isCredit) ...[
                    SizedBox(height: spacing.sm),
                    TextField(
                      key: const ValueKey('portal_payment_amount_paid'),
                      controller: _amountPaid,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.portalPaymentsAmountPaidLabel,
                        errorText: _amountPaidInvalid
                            ? l10n.portalPaymentsAmountPaidError
                            : null,
                      ),
                      // The slip was proved against the old figure.
                      onChanged: (_) => setState(() => _cardReceiptUrl = ''),
                    ),
                  ],
                  if (_takesTender) ...[
                    SizedBox(height: spacing.md),
                    PointySectionHeader(title: l10n.paymentMethodLabel),
                    _MethodPicker(
                      methods: _methods,
                      selected: _method,
                      onChanged: (method) => setState(() {
                        _method = method;
                        _cardReceiptUrl = '';
                      }),
                    ),
                    if (_usesBank &&
                        BankAccountPicker.isUseful(widget.bankAccounts)) ...[
                      SizedBox(height: spacing.sm),
                      BankAccountPicker(
                        accounts: widget.bankAccounts,
                        selectedId: _moneyAccountId,
                        onChanged: (id) => setState(() => _moneyAccountId = id),
                        dense: true,
                      ),
                    ],
                    if (_method == PaymentMethod.card.apiValue &&
                        widget.day.requireCardReceipt) ...[
                      SizedBox(height: spacing.sm),
                      _CardSlipRow(
                        scanned: _cardReceiptUrl.isNotEmpty,
                        onScan: _scanSlip,
                      ),
                    ],
                  ],
                  SizedBox(height: spacing.md),
                  PointySectionHeader(title: l10n.portalPaymentsCustomerLabel),
                  _CustomerRow(
                    name: _customerName,
                    hasCustomer: _customerId != null,
                    missing: _customerMissing,
                    onPick: widget.pickCustomer == null ? null : _pickCustomer,
                    onClear: () => setState(() {
                      _customerId = null;
                      _customerName = '';
                    }),
                  ),
                  if (_error.isNotEmpty) ...[
                    SizedBox(height: spacing.md),
                    PointyInlineMessage.error(
                      key: const ValueKey('portal_payment_record_error'),
                      message: _error,
                    ),
                  ],
                ],
              ),
            ),
          ),
          PointyStickyActionFooter(
            summary: Text(
              '${l10n.portalPaymentsInvoiceTotal}: ${formatMoney(_total)}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            primaryAction: FilledButton.icon(
              key: const ValueKey('portal_payment_record_button'),
              onPressed: _canSubmit ? _submit : null,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.receipt_long_outlined),
              label: Text(l10n.portalPaymentsRecordAction),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomer() async {
    final pick = widget.pickCustomer;
    if (pick == null) return;
    final customer = await pick(context);
    if (customer == null || !mounted) return;
    setState(() {
      _customerId = customer.id;
      _customerName = customer.fullName;
    });
  }

  Future<void> _scanSlip() async {
    final paid = _paidNow;
    if (paid == null || paid <= 0) return;
    final terminals =
        await (widget.loadTrustedTerminalIds?.call() ??
            Future<List<String>>.value(const []));
    if (!mounted) return;
    final receipt = await showCardReceiptValidationDialog(
      context: context,
      expectedAmount: paid,
      trustedTerminalIds: terminals,
    );
    if (receipt == null || !mounted) return;
    setState(() => _cardReceiptUrl = receipt.sourceUrl);
  }

  Future<void> _submit() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = '';
    });
    final result = await widget.onRecord(
      PortalPaymentRecordDraft(
        registerSessionId: sessionId,
        isCredit: _isCredit,
        paymentMethod: _takesTender ? _method : '',
        amountPaid: _isCredit ? _paidNow : null,
        customerId: _customerId,
        cardReceiptUrl: _method == PaymentMethod.card.apiValue
            ? _cardReceiptUrl
            : '',
        moneyAccountId: _takesTender && _usesBank ? _moneyAccountId : null,
        allowPendingSale: _isPendingSale && _differentTopUp,
        expectedTotal: _total,
      ),
    );
    if (!mounted) return;
    switch (result) {
      case Ok<PortalPaymentOrder>(value: final order):
        Navigator.of(context).pop(PortalPaymentSheetOutcome(order: order));
      case Error<PortalPaymentOrder>(exception: final exception):
        setState(() {
          _busy = false;
          _error = portalPaymentFailureMessage(exception, l10n);
        });
    }
  }

  Future<void> _link(PortalPaymentCandidate candidate) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = '';
    });
    final result = await widget.onLink(candidate);
    if (!mounted) return;
    switch (result) {
      case Ok<PortalPaymentOrder>(value: final order):
        Navigator.of(
          context,
        ).pop(PortalPaymentSheetOutcome(order: order, linked: true));
      case Error<PortalPaymentOrder>(exception: final exception):
        setState(() {
          _busy = false;
          _error = portalPaymentFailureMessage(exception, l10n);
        });
    }
  }
}

class _PaymentHeader extends StatelessWidget {
  const _PaymentHeader({required this.payment, required this.providerName});

  final PortalPayment payment;
  final String providerName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final who = payment.subscriberName.isEmpty
        ? payment.subscriberRef
        : '${payment.subscriberName} · ${payment.subscriberRef}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatMoney(payment.amount ?? 0),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(who, style: theme.textTheme.titleMedium),
        Text(
          [
            if (payment.paidAt != null) formatDateTime(payment.paidAt!),
            l10n.portalPaymentsSerial(payment.reference),
          ].join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        if (payment.cost != null)
          Text(
            l10n.portalPaymentsFloatCost(
              providerName,
              formatMoney(payment.cost!),
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
      ],
    );
  }
}

class _PendingSaleSection extends StatelessWidget {
  const _PendingSaleSection({
    required this.payment,
    required this.busy,
    required this.differentTopUp,
    required this.onLink,
    required this.onDifferentTopUp,
  });

  final PortalPayment payment;
  final bool busy;
  final bool differentTopUp;
  final ValueChanged<PortalPaymentCandidate> onLink;
  final ValueChanged<bool> onDifferentTopUp;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailCallout(
          icon: Icons.link_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.portalPaymentsPendingTitle,
          message: l10n.portalPaymentsPendingBody,
        ),
        for (final candidate in payment.candidates)
          ListTile(
            key: ValueKey(
              'portal_payment_candidate_${candidate.fulfillmentId}',
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.receipt_outlined),
            title: Text(
              l10n.portalPaymentsPendingCandidate(
                candidate.order.receiptNumber,
                candidate.soldAt == null
                    ? ''
                    : formatDateTime(candidate.soldAt!),
              ),
            ),
            subtitle: candidate.order.cashierName.isEmpty
                ? null
                : Text(candidate.order.cashierName),
            trailing: OutlinedButton(
              onPressed: busy ? null : () => onLink(candidate),
              child: Text(l10n.portalPaymentsLinkAction),
            ),
          ),
        CheckboxListTile(
          key: const ValueKey('portal_payment_different_top_up'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: differentTopUp,
          onChanged: busy ? null : (value) => onDifferentTopUp(value ?? false),
          title: Text(l10n.portalPaymentsDifferentTopUp),
        ),
      ],
    );
  }
}

class _MethodPicker extends StatelessWidget {
  const _MethodPicker({
    required this.methods,
    required this.selected,
    required this.onChanged,
  });

  final List<String> methods;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in methods)
          ChoiceChip(
            key: ValueKey('portal_payment_method_$value'),
            avatar: Icon(
              paymentMethodIcon(PaymentMethod.fromApiValue(value)),
              size: 18,
            ),
            label: Text(
              paymentMethodLabel(l10n, PaymentMethod.fromApiValue(value)),
            ),
            selected: value == selected,
            onSelected: (_) => onChanged(value),
          ),
      ],
    );
  }
}

class _CardSlipRow extends StatelessWidget {
  const _CardSlipRow({required this.scanned, required this.onScan});

  final bool scanned;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (scanned) {
      return PointyInlineMessage.success(
        message: l10n.portalPaymentsCardReceiptScanned,
        compact: true,
      );
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.portalPaymentsCardReceiptRequired,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const ValueKey('portal_payment_scan_slip'),
          onPressed: onScan,
          icon: const Icon(Icons.qr_code_scanner_outlined),
          label: Text(l10n.portalPaymentsCardReceiptScan),
        ),
      ],
    );
  }
}

class _CustomerRow extends StatelessWidget {
  const _CustomerRow({
    required this.name,
    required this.hasCustomer,
    required this.missing,
    required this.onPick,
    required this.onClear,
  });

  final String name;
  final bool hasCustomer;
  final bool missing;
  final VoidCallback? onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              hasCustomer ? Icons.person_outline : Icons.person_off_outlined,
              color: hasCustomer ? colors.ink : colors.mutedInk,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hasCustomer && name.isNotEmpty
                    ? name
                    : l10n.portalPaymentsCustomerNone,
              ),
            ),
            if (hasCustomer)
              TextButton(
                onPressed: onClear,
                child: Text(l10n.portalPaymentsCustomerClear),
              ),
            if (onPick != null)
              OutlinedButton(
                key: const ValueKey('portal_payment_pick_customer'),
                onPressed: onPick,
                child: Text(l10n.portalPaymentsCustomerPick),
              ),
          ],
        ),
        if (missing)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              l10n.portalPaymentsCustomerRequired,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
      ],
    );
  }
}
