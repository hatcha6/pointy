import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/customer_activity.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/payment_proof_printer.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/record_payment_dialog.dart';
import '../../../shared/components/pointy_progress.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';

/// Opens the focused collect-debt flow as a dialog (used from the POS).
Future<void> showCollectDebtDialog(
  BuildContext context, {
  required ContactRepository contactRepository,
  required PrintingRepository printingRepository,
  required ShopSettingsRepository shopSettingsRepository,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => CollectDebtDialog(
      contactRepository: contactRepository,
      printingRepository: printingRepository,
      shopSettingsRepository: shopSettingsRepository,
    ),
  );
}

/// Focused, cashier-facing debt-collection dialog: pick a customer, see only
/// their outstanding total, and collect a cash/card/transfer payment (the
/// backend allocates it oldest-first across the customer's open debt —
/// including invoices another cashier issued). Shows NO invoice history or
/// customer editing, so cashiers keep seeing only their own business.
class CollectDebtDialog extends StatefulWidget {
  const CollectDebtDialog({
    super.key,
    required this.contactRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
  });

  final ContactRepository contactRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  State<CollectDebtDialog> createState() => _CollectDebtDialogState();
}

class _CollectDebtDialogState extends State<CollectDebtDialog> {
  Customer? _customer;
  CustomerSalesSummary? _summary;
  bool _isLoadingSummary = false;
  bool _hasSummaryError = false;
  bool _isRecording = false;
  bool _justCollected = false;
  bool _hasPaymentError = false;
  final Map<String, String> _idempotencyKeys = {};
  late final PaymentProofPrinter _paymentProofPrinter = PaymentProofPrinter(
    printingRepository: widget.printingRepository,
    shopSettingsRepository: widget.shopSettingsRepository,
  );

  Future<void> _pickCustomer() async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (customer == null || !mounted) {
      return;
    }
    setState(() {
      _customer = customer;
      _summary = null;
      _hasSummaryError = false;
      _justCollected = false;
      _hasPaymentError = false;
    });
    await _loadSummary();
  }

  Future<void> _loadSummary() async {
    final customer = _customer;
    if (customer == null) {
      return;
    }
    setState(() => _isLoadingSummary = true);
    final result = await widget.contactRepository.loadCustomerSalesSummary(
      customer.id,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      switch (result) {
        case Ok<CustomerSalesSummary>():
          _summary = result.value;
          _hasSummaryError = false;
        case Error<CustomerSalesSummary>():
          _summary = null;
          _hasSummaryError = true;
      }
      _isLoadingSummary = false;
    });
  }

  Future<void> _collect() async {
    final customer = _customer;
    final summary = _summary;
    if (customer == null || summary == null || _isRecording) {
      return;
    }
    final outstanding = summary.outstandingBalance;
    if (outstanding <= 0.005) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final trustedTerminalIds = await widget.shopSettingsRepository
        .loadTrustedCardTerminalIds();
    if (!mounted) {
      return;
    }
    final result = await showRecordPaymentDialog(
      context,
      title: l10n.customerAccountPaymentTitle,
      maxAmount: outstanding,
      balanceLabel: l10n.customerAccountPaymentOutstandingValue(
        formatMoney(outstanding),
      ),
      methods: customerPaymentMethodOptions(l10n),
      proofToggleLabel: l10n.invoicePaymentPrintProofLabel,
      trustedCardTerminalIds: trustedTerminalIds,
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _isRecording = true;
      _justCollected = false;
      _hasPaymentError = false;
    });
    // Signature-based idempotency: an accidental double-submit is a server no-op
    // (the card receipt URL is part of the key so distinct swipes aren't deduped).
    final signature =
        'collect:${customer.id}:${result.methodApiValue}:'
        '${result.amount.toStringAsFixed(2)}:${result.cardReceiptUrl}';
    final key = _idempotencyKeys.putIfAbsent(
      signature,
      () => 'collect-debt:${generateAnalyticsEventId()}',
    );
    final recordResult = await widget.contactRepository
        .recordCustomerAccountPayment(
          customer.id,
          method: result.methodApiValue,
          amount: result.amount,
          cardReceiptUrl: result.cardReceiptUrl,
          idempotencyKey: key,
        );
    if (!mounted) {
      return;
    }
    final updatedSummary = switch (recordResult) {
      Ok<CustomerSalesSummary>(value: final value) => value,
      Error<CustomerSalesSummary>() => null,
    };
    setState(() {
      _isRecording = false;
      if (updatedSummary != null) {
        _idempotencyKeys.remove(signature);
        _summary = updatedSummary;
        _justCollected = true;
      } else {
        _hasPaymentError = true;
      }
    });
    if (updatedSummary != null && result.printProof) {
      // Best-effort: the payment is recorded; a print failure must not surface
      // as a collection failure.
      await _printProof(
        customer: customer,
        summary: updatedSummary,
        result: result,
      );
    }
  }

  Future<void> _printProof({
    required Customer customer,
    required CustomerSalesSummary summary,
    required RecordPaymentResult result,
  }) async {
    final paymentId = summary.representativePaymentId;
    if (paymentId == null) {
      return;
    }
    final phone = customer.phone.trim();
    await _paymentProofPrinter.printCustomerAccountReceipt(
      paymentId: paymentId,
      partyName: customer.fullName,
      partyContact: phone.isNotEmpty ? phone : customer.customerNumber,
      amount: result.amount,
      method: PaymentMethod.fromApiValue(result.methodApiValue),
      balanceAfter: summary.outstandingBalance,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.collectDebtTitle),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TutorTarget(
              anchor: TutorAnchor.collectDebtPickCustomerButton,
              child: FilledButton.icon(
                key: const ValueKey('collect_debt_pick_customer'),
                onPressed: _isRecording ? null : _pickCustomer,
                icon: const Icon(Icons.person_search_outlined),
                label: Text(
                  _customer == null
                      ? l10n.collectDebtPickCustomer
                      : l10n.collectDebtChangeCustomer,
                ),
              ),
            ),
            if (_customer != null) ...[
              const SizedBox(height: 16),
              _buildCustomerSection(l10n),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.closeButton),
        ),
      ],
    );
  }

  Widget _buildCustomerSection(AppLocalizations l10n) {
    final customer = _customer!;
    final theme = Theme.of(context);
    if (_isLoadingSummary) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: PointySpinner()),
      );
    }
    if (_hasSummaryError) {
      return Text(
        l10n.collectDebtLoadError,
        style: TextStyle(color: theme.colorScheme.error),
      );
    }
    final outstanding = _summary?.outstandingBalance ?? 0;
    final hasDebt = outstanding > 0.005;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(customer.fullName, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          hasDebt
              ? l10n.collectDebtOutstanding(formatMoney(outstanding))
              : l10n.collectDebtNoDebt,
          style: theme.textTheme.bodyLarge,
        ),
        if (_justCollected) ...[
          const SizedBox(height: 8),
          Text(
            l10n.collectDebtRecordedMessage,
            style: TextStyle(color: theme.colorScheme.primary),
          ),
        ],
        if (_hasPaymentError) ...[
          const SizedBox(height: 8),
          Text(
            l10n.collectDebtFailedMessage,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        if (hasDebt) ...[
          const SizedBox(height: 16),
          TutorTarget(
            anchor: TutorAnchor.collectDebtRecordPaymentButton,
            child: FilledButton.icon(
              key: const ValueKey('collect_debt_record_payment'),
              onPressed: _isRecording ? null : _collect,
              icon: _isRecording
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.payments_outlined),
              label: Text(l10n.collectDebtRecordPayment),
            ),
          ),
        ],
      ],
    );
  }
}
