import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_kinds.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/formatters.dart';
import '../../direct_services/foreign_amount.dart';
import '../../view_models/bill_flow_view_model.dart';
import '../../view_models/service_blocker.dart';
import '../../view_models/service_quote_controller.dart';
import 'airtime_phone_step.dart';
import 'service_flag.dart';
import 'service_summary_card.dart';
import 'service_texts.dart';
import 'service_timeline.dart';

/// The last step of a bill: everything the cashier will read back to the
/// customer, the price the server gave for exactly that, the plain statement
/// that it cannot be taken back, what happens next — and the button.
class BillSummaryStep extends StatelessWidget {
  const BillSummaryStep({
    super.key,
    required this.viewModel,
    required this.onAdd,
    this.onTransferBalance,
  });

  final BillFlowViewModel viewModel;

  /// Null on a till that cannot sell.
  final VoidCallback? onAdd;

  /// Moves money from the wallet into the voucher balance; null when this
  /// user cannot do it from here.
  final Future<bool> Function()? onTransferBalance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final vm = viewModel;
    final country = vm.country;
    final biller = vm.biller;
    final quote = vm.quote.ready;
    final unit = biller == null
        ? ''
        : serviceCurrencyLabel(
            l10n,
            country,
            biller.amountCurrency,
            directory: vm.catalog.directory,
          );
    final accountLabel = vm.needsInvoice
        ? l10n.posBillAccountLabelContract
        : billAccountLabel(l10n, vm.type);
    final amount = quote?.receiveAmount ?? vm.amount;
    final blocker = vm.blocker;
    final balance = vm.catalog.directory?.balance;
    final isPrepaidElectricity =
        vm.type == BillType.electricity && (biller?.isPrepaid ?? false);

    final rows = [
      ServiceSummaryRow(
        label: l10n.posServicesSummaryCountry,
        value: country?.label,
        leading: country == null
            ? null
            : ServiceFlag(code: country.code, width: 24, height: 16),
      ),
      ServiceSummaryRow(
        label: l10n.posServicesSummaryProvider,
        value: biller?.label,
      ),
      ServiceSummaryRow(label: accountLabel, value: vm.account, ltr: true),
      if (vm.needsInvoice)
        ServiceSummaryRow(
          label: l10n.posBillInvoiceLabel,
          value: vm.invoice,
          ltr: true,
        ),
      if (vm.plan != null)
        ServiceSummaryRow(
          label: l10n.posServicesSummaryPlan,
          value: vm.plan!.label,
        ),
      ServiceSummaryRow(
        label: l10n.posServicesSummaryAmount,
        value: amount == null || amount.isEmpty
            ? null
            : '${formatForeignAmountText(amount)} $unit',
        emphasis: true,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServiceSummaryCard(
          key: const ValueKey('bill_summary'),
          title: l10n.posServicesSummaryTitle,
          rows: rows,
          priceLabel: l10n.posServicesSummaryPays,
          price: quote?.price,
          isPricing: vm.quote.status == ServiceQuoteStatus.loading,
          balanceText: balance == null
              ? null
              : l10n.posVoucherMenuBalance(formatMoney(balance)),
          exceedsBalance: quote?.exceedsFloat == true,
          onTransferBalance: onTransferBalance == null
              ? null
              : () async {
                  if (await onTransferBalance!()) {
                    unawaited(vm.catalog.reload());
                    vm.quote.retry();
                  }
                },
          truth: l10n.posBillTruth,
          extraNotice: isPrepaidElectricity ? l10n.posBillPrepaidNote : null,
          addLabel: l10n.posServicesAddToCart,
          blockerText: blocker == null
              ? null
              : serviceBlockerText(l10n, blocker, accountLabel: accountLabel),
          blockerIsWaiting: blocker?.isWaiting ?? false,
          onRetry: blocker == null
              ? null
              : blocker.needsFreshList
              ? vm.refreshList
              : blocker.reason == ServiceBlockReason.countryFailed
              ? vm.retryCountry
              : blocker.isRetryable
              ? vm.quote.retry
              : null,
          retryLabel: blocker != null && blocker.needsFreshList
              ? l10n.posServicesRefreshList
              : null,
          onAdd: vm.canAdd ? onAdd : null,
        ),
        if (vm.addRefused) ...[
          const SizedBox(height: 10),
          PointyInlineMessage.warning(
            key: const ValueKey('service_add_refused'),
            message: l10n.posServicesAddRefused,
            icon: Icons.lock_clock_rounded,
            compact: true,
          ),
        ],
        const SizedBox(height: 14),
        const ServiceTimeline(),
      ],
    );
  }
}
