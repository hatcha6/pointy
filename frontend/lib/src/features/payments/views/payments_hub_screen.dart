import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/models/purchase_submission.dart'
    show SupplierPayment, SupplierPaymentMethod;
import '../../../data/models/sale_order.dart' show PaymentMethod;
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../printing/views/print_audit_sheet.dart';
import '../models/payment_record.dart';
import '../view_models/payments_hub_view_model.dart';

/// Centralized money ledger (الخزينة): customer money-IN and supplier money-OUT
/// in two filterable, paginated segments with per-row proof reprint + print log.
class PaymentsHubScreen extends StatelessWidget {
  const PaymentsHubScreen({
    super.key,
    required this.viewModel,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    required this.navigation,
  });

  final PaymentsHubViewModel viewModel;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.payments,
            navigation: navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.paymentsHubTitle),
            actions: [
              IconButton(
                tooltip: l10n.paymentsHubRefreshTooltip,
                onPressed: viewModel.refreshActive,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.viewPayments,
            child: _PaymentsHubBody(
              viewModel: viewModel,
              printingRepository: printingRepository,
              shopSettingsRepository: shopSettingsRepository,
            ),
          ),
        );
      },
    );
  }
}

class _PaymentsHubBody extends StatelessWidget {
  const _PaymentsHubBody({
    required this.viewModel,
    required this.printingRepository,
    required this.shopSettingsRepository,
  });

  final PaymentsHubViewModel viewModel;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final isCustomer = viewModel.segment == PaymentsHubSegment.customer;

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<PaymentsHubSegment>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: PaymentsHubSegment.customer,
                icon: const Icon(Icons.south_west),
                label: Text(l10n.paymentsHubSegmentCustomer),
              ),
              ButtonSegment(
                value: PaymentsHubSegment.supplier,
                icon: const Icon(Icons.north_east),
                label: Text(l10n.paymentsHubSegmentSupplier),
              ),
            ],
            selected: {viewModel.segment},
            onSelectionChanged: (selection) =>
                viewModel.selectSegment(selection.first),
          ),
          SizedBox(height: spacing.md),
          _FilterBar(
            range: isCustomer
                ? viewModel.customerRange
                : viewModel.supplierRange,
            methodValue: isCustomer
                ? viewModel.customerMethod?.apiValue
                : viewModel.supplierMethod?.apiValue,
            methodOptions: isCustomer
                ? _customerMethodOptions(l10n)
                : _supplierMethodOptions(l10n),
            onRangeChanged: isCustomer
                ? viewModel.setCustomerRange
                : viewModel.setSupplierRange,
            onMethodChanged: isCustomer
                ? (value) => viewModel.setCustomerMethod(
                    value == null ? null : PaymentMethod.fromApiValue(value),
                  )
                : (value) => viewModel.setSupplierMethod(
                    value == null
                        ? null
                        : SupplierPaymentMethod.fromApiValue(value),
                  ),
            onClearFilters: isCustomer
                ? viewModel.clearCustomerFilters
                : viewModel.clearSupplierFilters,
          ),
          SizedBox(height: spacing.md),
          Expanded(
            child: isCustomer
                ? _CustomerLedger(
                    viewModel: viewModel,
                    printingRepository: printingRepository,
                    shopSettingsRepository: shopSettingsRepository,
                  )
                : _SupplierLedger(
                    viewModel: viewModel,
                    printingRepository: printingRepository,
                    shopSettingsRepository: shopSettingsRepository,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Shared date-range + payment-method filter row for both ledgers.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.range,
    required this.methodValue,
    required this.methodOptions,
    required this.onRangeChanged,
    required this.onMethodChanged,
    required this.onClearFilters,
  });

  final DateTimeRange? range;
  final String? methodValue;
  final List<_MethodOption> methodOptions;
  final ValueChanged<DateTimeRange?> onRangeChanged;
  final ValueChanged<String?> onMethodChanged;

  /// Drops the date window and the method together in one reload. Nulling the
  /// two setters in turn would refetch the ledger twice.
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final hasFilters = range != null || methodValue != null;

    return Wrap(
      spacing: spacing.sm,
      runSpacing: spacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: () => _pickRange(context),
          icon: const Icon(Icons.event_outlined),
          label: Text(
            range == null
                ? l10n.paymentsHubFilterDateRange
                : l10n.paymentsHubFilterDateRangeValue(
                    formatDate(range!.start),
                    formatDate(range!.end),
                  ),
          ),
        ),
        _MethodDropdown(
          value: methodValue,
          options: methodOptions,
          onChanged: onMethodChanged,
        ),
        if (hasFilters)
          TextButton.icon(
            onPressed: onClearFilters,
            icon: const Icon(Icons.clear),
            label: Text(l10n.paymentsHubClearFilters),
          ),
      ],
    );
  }

  Future<void> _pickRange(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: range,
    );
    if (picked != null) {
      onRangeChanged(picked);
    }
  }
}

/// Segment-aware method filter. Works off an api-value string + a per-segment
/// option list so the supplier segment can offer its credit/refund methods
/// (which the customer [PaymentMethod] enum doesn't model).
class _MethodDropdown extends StatelessWidget {
  const _MethodDropdown({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String? value;
  final List<_MethodOption> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: value,
        icon: const Icon(Icons.expand_more),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(l10n.paymentsHubFilterAllMethods),
          ),
          for (final option in options)
            DropdownMenuItem<String?>(
              value: option.apiValue,
              child: Text(option.label),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// One selectable option in the method filter (its backend api value + label).
class _MethodOption {
  const _MethodOption({required this.apiValue, required this.label});

  final String apiValue;
  final String label;
}

List<_MethodOption> _customerMethodOptions(AppLocalizations l10n) {
  return [
    for (final method in PaymentMethod.values)
      _MethodOption(
        apiValue: method.apiValue,
        label: _customerMethodLabel(l10n, method),
      ),
  ];
}

List<_MethodOption> _supplierMethodOptions(AppLocalizations l10n) {
  return [
    for (final method in SupplierPaymentMethod.values)
      _MethodOption(
        apiValue: method.apiValue,
        label: _supplierMethodLabel(l10n, method),
      ),
  ];
}

class _CustomerLedger extends StatelessWidget {
  const _CustomerLedger({
    required this.viewModel,
    required this.printingRepository,
    required this.shopSettingsRepository,
  });

  final PaymentsHubViewModel viewModel;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDataList<CustomerPaymentRecord>(
      items: viewModel.customerPayments,
      onLoadMore: viewModel.loadMoreCustomerPayments,
      hasMore: viewModel.hasMoreCustomer,
      isLoadingInitial: viewModel.isLoadingCustomer,
      isLoadingMore: viewModel.isLoadingMoreCustomer,
      hasError: viewModel.hasCustomerError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.paymentsHubLoadError,
        icon: Icons.account_balance_wallet_outlined,
        action: OutlinedButton.icon(
          onPressed: viewModel.loadCustomerPayments,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => QueryEmptyState(
        icon: Icons.south_west,
        search: '',
        hasFilters:
            viewModel.customerRange != null || viewModel.customerMethod != null,
        emptyTitle: l10n.paymentsHubCustomerEmptyTitle,
        emptyMessage: l10n.paymentsHubCustomerEmptyMessage,
        onClear: viewModel.clearCustomerFilters,
      ),
      itemBuilder: (context, payment) => _CustomerPaymentTile(
        payment: payment,
        printingRepository: printingRepository,
        shopSettingsRepository: shopSettingsRepository,
      ),
    );
  }
}

class _SupplierLedger extends StatelessWidget {
  const _SupplierLedger({
    required this.viewModel,
    required this.printingRepository,
    required this.shopSettingsRepository,
  });

  final PaymentsHubViewModel viewModel;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDataList<SupplierPayment>(
      items: viewModel.supplierPayments,
      onLoadMore: viewModel.loadMoreSupplierPayments,
      hasMore: viewModel.hasMoreSupplier,
      isLoadingInitial: viewModel.isLoadingSupplier,
      isLoadingMore: viewModel.isLoadingMoreSupplier,
      hasError: viewModel.hasSupplierError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.paymentsHubLoadError,
        icon: Icons.account_balance_wallet_outlined,
        action: OutlinedButton.icon(
          onPressed: viewModel.loadSupplierPayments,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => QueryEmptyState(
        icon: Icons.north_east,
        search: '',
        hasFilters:
            viewModel.supplierRange != null || viewModel.supplierMethod != null,
        emptyTitle: l10n.paymentsHubSupplierEmptyTitle,
        emptyMessage: l10n.paymentsHubSupplierEmptyMessage,
        onClear: viewModel.clearSupplierFilters,
      ),
      itemBuilder: (context, payment) => _SupplierPaymentTile(
        payment: payment,
        printingRepository: printingRepository,
        shopSettingsRepository: shopSettingsRepository,
      ),
    );
  }
}

class _CustomerPaymentTile extends StatelessWidget {
  const _CustomerPaymentTile({
    required this.payment,
    required this.printingRepository,
    required this.shopSettingsRepository,
  });

  final CustomerPaymentRecord payment;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final party = payment.customerName?.trim().isNotEmpty == true
        ? payment.customerName!.trim()
        : l10n.paymentsHubWalkInCustomer;

    return PointyDataRow(
      leading: Icon(
        _customerMethodIcon(payment.method),
        color: colors.primaryStrong,
      ),
      title: party,
      subtitle: _customerSubtitle(l10n).join(' • '),
      badges: [
        PointyStatusPill(
          label: _customerMethodLabel(l10n, payment.method),
          icon: _customerMethodIcon(payment.method),
          color: colors.primaryStrong,
        ),
      ],
      actions: [
        _PaymentRowMenu(
          onReprint: () => _reprintProof(context),
          onPrintLog: () => _showPrintLog(context),
        ),
      ],
      trailing: _AmountText(amount: payment.amount, color: colors.success),
    );
  }

  List<String> _customerSubtitle(AppLocalizations l10n) {
    return [
      if (payment.orderReceiptNumber?.trim().isNotEmpty ?? false)
        l10n.paymentsHubInvoiceValue(payment.orderReceiptNumber!.trim()),
      if (payment.commissionAmount > 0.005)
        l10n.paymentsHubCommissionValue(formatMoney(payment.commissionAmount)),
      if (payment.externalReference.trim().isNotEmpty)
        l10n.paymentsHubReferenceValue(payment.externalReference.trim()),
      if (payment.createdByUsername?.trim().isNotEmpty ?? false)
        l10n.paymentsHubRecordedByValue(payment.createdByUsername!.trim()),
      if (payment.paidAt != null) formatDateTime(payment.paidAt!),
    ];
  }

  Future<void> _reprintProof(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    const labels = OrderDocumentLabels.arabic();
    final shopSettings = await _loadShopSettings(shopSettingsRepository);
    final proof = PaymentProof(
      kind: PaymentProofKind.receipt,
      reference: '${payment.id}',
      partyName: payment.customerName?.trim().isNotEmpty == true
          ? payment.customerName!.trim()
          : labels.walkInCustomer,
      relatedDocumentNumber: payment.orderReceiptNumber,
      amount: payment.amount,
      method: labels.paymentMethodLabel(payment.method),
      commissionAmount: payment.commissionAmount,
      externalReference: payment.externalReference,
      handledBy: payment.createdByUsername,
      createdAt: payment.paidAt ?? payment.createdAt,
    );
    final result = await printingRepository.printProofOfPayment(
      proof: proof,
      paymentId: payment.id,
      paymentKind: PrintAuditPaymentKind.customer,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(
        shopSettingsRepository,
        shopSettings,
      ),
    );
    if (!context.mounted) {
      return;
    }
    _showReprintResult(messenger, l10n, result.isSuccess);
  }

  Future<void> _showPrintLog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return showPrintAuditSheet(
      context: context,
      printingRepository: printingRepository,
      documentType: PrintAuditDocumentType.paymentReceipt,
      documentId: payment.id,
      paymentKind: PrintAuditPaymentKind.customer,
      documentNumber: payment.orderReceiptNumber?.trim().isNotEmpty == true
          ? payment.orderReceiptNumber!.trim()
          : l10n.paymentsHubInvoiceValue('${payment.id}'),
    );
  }
}

class _SupplierPaymentTile extends StatelessWidget {
  const _SupplierPaymentTile({
    required this.payment,
    required this.printingRepository,
    required this.shopSettingsRepository,
  });

  final SupplierPayment payment;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final party = payment.supplierName.trim().isNotEmpty
        ? payment.supplierName.trim()
        : l10n.paymentsHubUnknownSupplier;

    return PointyDataRow(
      leading: Icon(_supplierMethodIcon(payment.method), color: colors.warning),
      title: party,
      subtitle: _supplierSubtitle(l10n).join(' • '),
      badges: [
        PointyStatusPill(
          label: _supplierMethodLabel(l10n, payment.method),
          icon: _supplierMethodIcon(payment.method),
          color: colors.warning,
        ),
      ],
      actions: [
        _PaymentRowMenu(
          onReprint: () => _reprintProof(context),
          onPrintLog: () => _showPrintLog(context),
        ),
      ],
      trailing: _AmountText(amount: payment.amount, color: colors.warning),
    );
  }

  List<String> _supplierSubtitle(AppLocalizations l10n) {
    return [
      if (payment.purchaseOrderNumber?.trim().isNotEmpty ?? false)
        l10n.paymentsHubPurchaseOrderValue(payment.purchaseOrderNumber!.trim()),
      if (payment.reference.trim().isNotEmpty)
        l10n.paymentsHubReferenceValue(payment.reference.trim()),
      if (payment.createdByUsername?.trim().isNotEmpty ?? false)
        l10n.paymentsHubRecordedByValue(payment.createdByUsername!.trim()),
      if (payment.paidAt != null) formatDateTime(payment.paidAt!),
    ];
  }

  Future<void> _reprintProof(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final shopSettings = await _loadShopSettings(shopSettingsRepository);
    final proof = PaymentProof(
      kind: PaymentProofKind.disbursement,
      reference: '${payment.id}',
      partyName: payment.supplierName.trim().isNotEmpty
          ? payment.supplierName.trim()
          : l10n.paymentsHubUnknownSupplier,
      relatedDocumentNumber: payment.purchaseOrderNumber,
      amount: payment.amount,
      method: _supplierMethodLabel(l10n, payment.method),
      externalReference: payment.reference,
      handledBy: payment.createdByUsername,
      createdAt: payment.paidAt ?? payment.createdAt,
    );
    final result = await printingRepository.printProofOfPayment(
      proof: proof,
      paymentId: payment.id,
      paymentKind: PrintAuditPaymentKind.supplier,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(
        shopSettingsRepository,
        shopSettings,
      ),
    );
    if (!context.mounted) {
      return;
    }
    _showReprintResult(messenger, l10n, result.isSuccess);
  }

  Future<void> _showPrintLog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return showPrintAuditSheet(
      context: context,
      printingRepository: printingRepository,
      documentType: PrintAuditDocumentType.paymentReceipt,
      documentId: payment.id,
      paymentKind: PrintAuditPaymentKind.supplier,
      documentNumber: payment.purchaseOrderNumber?.trim().isNotEmpty == true
          ? payment.purchaseOrderNumber!.trim()
          : l10n.paymentsHubPurchaseOrderValue('${payment.id}'),
    );
  }
}

class _PaymentRowMenu extends StatelessWidget {
  const _PaymentRowMenu({required this.onReprint, required this.onPrintLog});

  final VoidCallback onReprint;
  final VoidCallback onPrintLog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PopupMenuButton<_PaymentRowAction>(
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case _PaymentRowAction.reprint:
            onReprint();
          case _PaymentRowAction.printLog:
            onPrintLog();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<_PaymentRowAction>(
          value: _PaymentRowAction.reprint,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(l10n.paymentsHubReprintProofAction),
          ),
        ),
        PopupMenuItem<_PaymentRowAction>(
          value: _PaymentRowAction.printLog,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.manage_search_outlined),
            title: Text(l10n.paymentsHubPrintLogAction),
          ),
        ),
      ],
    );
  }
}

class _AmountText extends StatelessWidget {
  const _AmountText({required this.amount, required this.color});

  final double amount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: color,
      fontWeight: FontWeight.w800,
    );
    return Text(
      formatMoney(amount),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style == null ? null : PointyTypography.numeric(style),
    );
  }
}

enum _PaymentRowAction { reprint, printLog }

void _showReprintResult(
  ScaffoldMessengerState messenger,
  AppLocalizations l10n,
  bool success,
) {
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(
          success
              ? l10n.paymentsHubReprintSuccess
              : l10n.paymentsHubReprintError,
        ),
      ),
    );
}

Future<ShopSettings?> _loadShopSettings(
  ShopSettingsRepository repository,
) async {
  final result = await repository.loadSettings();
  return switch (result) {
    Ok<ShopSettings>(value: final settings) => settings,
    Error<ShopSettings>() => null,
  };
}

Future<Uint8List?> _loadShopLogoBytes(
  ShopSettingsRepository repository,
  ShopSettings? settings,
) async {
  final result = await repository.loadLogoBytes(settings);
  return switch (result) {
    Ok<Uint8List?>(value: final bytes) => bytes,
    Error<Uint8List?>() => null,
  };
}

String _customerMethodLabel(AppLocalizations l10n, PaymentMethod method) {
  return switch (method) {
    PaymentMethod.cash => l10n.paymentMethodCash,
    PaymentMethod.card => l10n.paymentMethodCard,
    PaymentMethod.transfer => l10n.paymentMethodTransfer,
    PaymentMethod.salaryDeduction => l10n.paymentMethodSalaryDeduction,
  };
}

IconData _customerMethodIcon(PaymentMethod method) {
  return switch (method) {
    PaymentMethod.cash => Icons.payments_outlined,
    PaymentMethod.card => Icons.credit_card_outlined,
    PaymentMethod.transfer => Icons.account_balance_outlined,
    PaymentMethod.salaryDeduction => Icons.badge_outlined,
  };
}

String _supplierMethodLabel(
  AppLocalizations l10n,
  SupplierPaymentMethod method,
) {
  return switch (method) {
    SupplierPaymentMethod.cash => l10n.paymentMethodCash,
    SupplierPaymentMethod.card => l10n.paymentMethodCard,
    SupplierPaymentMethod.transfer => l10n.paymentMethodTransfer,
    SupplierPaymentMethod.supplierCredit => l10n.supplierPaymentMethodCredit,
    SupplierPaymentMethod.refund => l10n.purchaseAdjustmentTypeRefund,
  };
}

IconData _supplierMethodIcon(SupplierPaymentMethod method) {
  return switch (method) {
    SupplierPaymentMethod.cash => Icons.payments_outlined,
    SupplierPaymentMethod.card => Icons.credit_card_outlined,
    SupplierPaymentMethod.transfer => Icons.account_balance_outlined,
    SupplierPaymentMethod.supplierCredit => Icons.savings_outlined,
    SupplierPaymentMethod.refund => Icons.keyboard_return_outlined,
  };
}
