import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/contact.dart';
import '../../../data/models/customer_activity.dart';
import '../../../data/models/payment_card.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payment_labels.dart';
import '../../../shared/payments/record_payment_dialog.dart';
import '../../../shared/responsive/responsive.dart';
import '../../register_sessions/views/sale_order_details_sheet.dart';
import '../view_models/customer_details_view_model.dart';

class CustomerDetailsScreen extends StatefulWidget {
  const CustomerDetailsScreen({
    super.key,
    required this.customer,
    required this.contactRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
  });

  final Customer customer;
  final ContactRepository contactRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  State<CustomerDetailsScreen> createState() => _CustomerDetailsScreenState();
}

class _CustomerDetailsScreenState extends State<CustomerDetailsScreen> {
  late final CustomerDetailsViewModel _viewModel = CustomerDetailsViewModel(
    contactRepository: widget.contactRepository,
    initialCustomer: widget.customer,
    shopSettingsRepository: widget.shopSettingsRepository,
    printingRepository: widget.printingRepository,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final customer = _viewModel.customer;
        return Scaffold(
          appBar: AppBar(
            title: Text(customer.fullName),
            actions: [
              IconButton(
                tooltip: l10n.refreshCustomerDetailsTooltip,
                onPressed: _viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: CustomerDetailsView(
              viewModel: _viewModel,
              onMerged: () => Navigator.of(context).maybePop(),
            ),
          ),
        );
      },
    );
  }
}

/// Embeddable customer details body: used by [CustomerDetailsScreen] as a
/// pushed route on compact widths, and by the contacts master-detail pane on
/// desktop.
class CustomerDetailsView extends StatelessWidget {
  const CustomerDetailsView({
    super.key,
    required this.viewModel,
    this.onMerged,
    this.onClaimed,
    this.onEdited,
  });

  final CustomerDetailsViewModel viewModel;

  /// Invoked after this customer is folded into another (it no longer exists).
  final VoidCallback? onMerged;

  /// Invoked after a placeholder card-customer is named (claimed).
  final VoidCallback? onClaimed;

  /// Invoked after the profile is edited (so list views can refresh the name).
  final VoidCallback? onEdited;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final customer = viewModel.customer;
        return AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: ListView(
            padding: EdgeInsets.all(spacing.lg),
            children: [
              _CustomerHero(customer: customer),
              SizedBox(height: spacing.md),
              if (viewModel.outstandingBalance > 0.005) ...[
                _OutstandingBalanceCallout(viewModel: viewModel),
                SizedBox(height: spacing.md),
              ],
              if (customer.isAutoCreated) ...[
                _UnclaimedCardCallout(
                  viewModel: viewModel,
                  onMerged: onMerged,
                  onClaimed: onClaimed,
                ),
                SizedBox(height: spacing.md),
              ],
              PointyDetailSection(
                title: l10n.customerProfileTitle,
                icon: Icons.badge_outlined,
                trailing: IconButton(
                  key: const ValueKey('edit_customer_button'),
                  tooltip: l10n.editContactTooltip,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: viewModel.isSaving ? null : () => _edit(context),
                ),
                child: _CustomerProfile(viewModel: viewModel),
              ),
              if (viewModel.creditLimitsEnforced) ...[
                SizedBox(height: spacing.md),
                PointyDetailSection(
                  title: l10n.customerCreditLimitTitle,
                  icon: Icons.account_balance_wallet_outlined,
                  child: _CustomerCreditLimit(viewModel: viewModel),
                ),
              ],
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.customerConsentTitle,
                icon: Icons.notifications_active_outlined,
                child: _CustomerConsent(viewModel: viewModel),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.paymentCardsTitle,
                icon: Icons.credit_card_outlined,
                child: _CustomerPaymentCards(viewModel: viewModel),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.customerSalesSummaryTitle,
                icon: Icons.summarize_outlined,
                child: _CustomerSalesSummary(viewModel: viewModel),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.customerInvoiceHistoryTitle,
                icon: Icons.receipt_long_outlined,
                child: _CustomerInvoiceHistory(viewModel: viewModel),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.customerAdjustmentHistoryTitle,
                icon: Icons.assignment_return_outlined,
                child: _CustomerAdjustmentHistory(viewModel: viewModel),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _edit(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final updated = await showEditCustomerSheet(
      context: context,
      repository: viewModel.repository,
      customer: viewModel.customer,
    );
    if (updated == null || !context.mounted) {
      return;
    }
    viewModel.applyUpdatedCustomer(updated);
    _showSnack(context, l10n.customerUpdatedMessage);
    onEdited?.call();
  }
}

/// How much this customer may owe. Three choices rather than one number,
/// because "follow the shop", "never cap this one" and "exactly this much" are
/// three different decisions an owner makes about three different customers.
class _CustomerCreditLimit extends StatefulWidget {
  const _CustomerCreditLimit({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  State<_CustomerCreditLimit> createState() => _CustomerCreditLimitState();
}

class _CustomerCreditLimitState extends State<_CustomerCreditLimit> {
  late CreditLimitPolicy _policy;
  late final TextEditingController _amountController;
  String? _amountError;

  @override
  void initState() {
    super.initState();
    final customer = widget.viewModel.customer;
    _policy = customer.creditLimitPolicy;
    _amountController = TextEditingController(
      text: customer.creditLimit == null
          ? ''
          : customer.creditLimit!.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  bool get _isDirty {
    final customer = widget.viewModel.customer;
    if (_policy != customer.creditLimitPolicy) {
      return true;
    }
    if (_policy != CreditLimitPolicy.custom) {
      return false;
    }
    return _parsedAmount() != customer.creditLimit;
  }

  double? _parsedAmount() {
    final text = _amountController.text.trim();
    if (text.isEmpty) {
      return null;
    }
    return double.tryParse(text);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final amount = _parsedAmount();
    if (_policy == CreditLimitPolicy.custom &&
        (amount == null || amount < 0)) {
      setState(() => _amountError = l10n.customerCreditLimitAmountRequired);
      return;
    }
    setState(() => _amountError = null);
    final ok = await widget.viewModel.setCreditLimit(
      policy: _policy,
      amount: amount,
    );
    if (!mounted) {
      return;
    }
    _showSnack(
      context,
      ok ? l10n.customerCreditLimitSaved : l10n.customerCreditLimitSaveError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final viewModel = widget.viewModel;
    final shopDefault = viewModel.shopDefaultCreditLimit;
    final effective = viewModel.effectiveCreditLimit;
    final available = viewModel.availableCredit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<CreditLimitPolicy>(
          key: const ValueKey('customer_credit_limit_policy'),
          segments: [
            ButtonSegment(
              value: CreditLimitPolicy.shopDefault,
              label: Text(l10n.customerCreditLimitPolicyShopDefault),
            ),
            ButtonSegment(
              value: CreditLimitPolicy.unlimited,
              label: Text(l10n.customerCreditLimitPolicyUnlimited),
            ),
            ButtonSegment(
              value: CreditLimitPolicy.custom,
              label: Text(l10n.customerCreditLimitPolicyCustom),
            ),
          ],
          selected: {_policy},
          onSelectionChanged: viewModel.isSaving
              ? null
              : (selection) => setState(() => _policy = selection.first),
        ),
        if (_policy == CreditLimitPolicy.shopDefault) ...[
          SizedBox(height: spacing.sm),
          Text(
            l10n.customerCreditLimitShopDefaultHint(
              shopDefault == null
                  ? l10n.customerCreditLimitNone
                  : formatMoney(shopDefault),
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (_policy == CreditLimitPolicy.custom) ...[
          SizedBox(height: spacing.sm),
          TextField(
            key: const ValueKey('customer_credit_limit_amount'),
            controller: _amountController,
            enabled: !viewModel.isSaving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l10n.customerCreditLimitAmountLabel,
              errorText: _amountError,
              prefixIcon: const Icon(Icons.attach_money),
            ),
          ),
        ],
        SizedBox(height: spacing.sm),
        Text(
          l10n.customerCreditLimitEffective(
            effective == null
                ? l10n.customerCreditLimitNone
                : formatMoney(effective),
          ),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (available != null)
          Text(
            l10n.customerCreditLimitAvailable(formatMoney(available)),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        SizedBox(height: spacing.sm),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton(
            key: const ValueKey('customer_credit_limit_save'),
            onPressed: viewModel.isSaving || !_isDirty ? null : _save,
            child: Text(l10n.saveButton),
          ),
        ),
      ],
    );
  }
}

class _CustomerConsent extends StatelessWidget {
  const _CustomerConsent({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  Future<void> _set(
    BuildContext context, {
    bool? marketingOptedOut,
    bool? doNotContact,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await viewModel.setConsent(
      marketingOptedOut: marketingOptedOut,
      doNotContact: doNotContact,
    );
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.customerConsentError)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final customer = viewModel.customer;
    final busy = viewModel.isSaving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: Text(l10n.customerMarketingAllowedLabel),
          subtitle: Text(l10n.customerMarketingAllowedHelp),
          value: !customer.marketingOptedOut && !customer.doNotContact,
          onChanged: busy || customer.doNotContact
              ? null
              : (value) => _set(context, marketingOptedOut: !value),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          title: Text(l10n.customerDoNotContactLabel),
          subtitle: Text(l10n.customerDoNotContactHelp),
          value: customer.doNotContact,
          onChanged: busy
              ? null
              : (value) => _set(context, doNotContact: value),
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}

class _CustomerHero extends StatelessWidget {
  const _CustomerHero({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailHero(
      icon: customer.marketingConsent
          ? Icons.campaign_outlined
          : Icons.person_outline,
      title: customer.fullName,
      pills: [
        PointyHeroPill(
          label: customer.isActive
              ? l10n.activeContactLabel
              : l10n.inactiveContactLabel,
          icon: customer.isActive
              ? Icons.check_circle_outline
              : Icons.pause_circle_outline,
        ),
        if (customer.customerNumber.trim().isNotEmpty)
          PointyHeroPill(
            label: customer.customerNumber,
            icon: Icons.badge_outlined,
          ),
        if (customer.phone.trim().isNotEmpty)
          PointyHeroPill(label: customer.phone, icon: Icons.phone_outlined),
        if (customer.marketingConsent)
          PointyHeroPill(
            label: l10n.marketingAllowedLabel,
            icon: Icons.campaign_outlined,
          ),
      ],
    );
  }
}

class _UnclaimedCardCallout extends StatelessWidget {
  const _UnclaimedCardCallout({
    required this.viewModel,
    this.onMerged,
    this.onClaimed,
  });

  final CustomerDetailsViewModel viewModel;
  final VoidCallback? onMerged;
  final VoidCallback? onClaimed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final busy = viewModel.isSaving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailCallout(
          icon: Icons.credit_card_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.unclaimedCardCustomerCalloutTitle,
          message: l10n.unclaimedCardCustomerCalloutBody,
        ),
        SizedBox(height: spacing.sm),
        Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.sm,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : () => _name(context),
              icon: const Icon(Icons.drive_file_rename_outline),
              label: Text(l10n.nameCustomerButton),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => _merge(context),
              icon: const Icon(Icons.merge_outlined),
              label: Text(l10n.mergeIntoCustomerButton),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _name(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _promptCustomerName(context);
    if (name == null || name.trim().isEmpty) {
      return;
    }
    final ok = await viewModel.claim(name.trim());
    if (!context.mounted) {
      return;
    }
    _showSnack(
      context,
      ok ? l10n.customerClaimedMessage : l10n.customerClaimFailedMessage,
    );
    if (ok) {
      onClaimed?.call();
    }
  }

  Future<void> _merge(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final target = await showCustomerPickerSheet(
      context: context,
      repository: viewModel.repository,
    );
    if (target == null ||
        !context.mounted ||
        target.id == viewModel.customer.id) {
      return;
    }
    final ok = await viewModel.mergeInto(target.id);
    if (!context.mounted) {
      return;
    }
    _showSnack(
      context,
      ok ? l10n.mergeCustomerSuccessMessage : l10n.mergeCustomerFailedMessage,
    );
    if (ok) {
      onMerged?.call();
    }
  }
}

/// Prominent "you owe X" callout + a primary [recordPayment] action, shown only
/// while the customer carries an outstanding balance on their account.
class _OutstandingBalanceCallout extends StatelessWidget {
  const _OutstandingBalanceCallout({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final busy = viewModel.isRecordingPayment;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailCallout(
          icon: Icons.account_balance_wallet_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.customerOutstandingBalanceCalloutTitle(
            formatMoney(viewModel.outstandingBalance),
          ),
          message: l10n.customerOutstandingBalanceCalloutBody,
        ),
        if (viewModel.hasPaymentError) ...[
          SizedBox(height: spacing.sm),
          PointyInlineMessage.error(message: l10n.customerAccountPaymentError),
        ],
        SizedBox(height: spacing.sm),
        FilledButton.icon(
          key: const ValueKey('record_customer_payment_button'),
          onPressed: busy ? null : () => _recordPayment(context),
          icon: busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.add_card_outlined),
          label: Text(l10n.recordCustomerPaymentButton),
        ),
      ],
    );
  }

  Future<void> _recordPayment(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final trustedTerminalIds = await viewModel.loadTrustedCardTerminalIds();
    if (!context.mounted) {
      return;
    }
    final result = await showRecordPaymentDialog(
      context,
      title: l10n.customerAccountPaymentTitle,
      maxAmount: viewModel.outstandingBalance,
      balanceLabel: l10n.customerAccountPaymentOutstandingValue(
        formatMoney(viewModel.outstandingBalance),
      ),
      methods: customerPaymentMethodOptions(l10n),
      proofToggleLabel: l10n.invoicePaymentPrintProofLabel,
      trustedCardTerminalIds: trustedTerminalIds,
    );
    if (result == null) {
      return;
    }

    final didRecord = await viewModel.recordAccountPayment(
      method: PaymentMethod.fromApiValue(result.methodApiValue),
      amount: result.amount,
      cardReceiptUrl: result.cardReceiptUrl,
      printProof: result.printProof,
    );
    if (!context.mounted || !didRecord) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(l10n.customerAccountPaymentSuccess)),
      );
  }
}

class _CustomerPaymentCards extends StatelessWidget {
  const _CustomerPaymentCards({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoadingCards && viewModel.cards.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasCardsError && viewModel.cards.isEmpty) {
      return PointyInlineMessage.error(message: l10n.paymentCardsLoadError);
    }
    if (viewModel.cards.isEmpty) {
      return PointyEmptyState(
        icon: Icons.credit_card_off_outlined,
        title: l10n.paymentCardsEmpty,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final card in viewModel.cards) ...[
          PointyDataRow(
            leading: const Icon(Icons.credit_card_outlined),
            title: card.displayName,
            subtitle: [
              if (card.cardScheme.isNotEmpty) card.cardScheme,
              if (card.lastSeenAt != null)
                l10n.paymentCardLastSeenValue(formatDate(card.lastSeenAt!)),
            ].join(' • '),
            trailing: IconButton(
              tooltip: l10n.reassignCardTooltip,
              icon: const Icon(Icons.swap_horiz_outlined),
              onPressed: viewModel.isSaving
                  ? null
                  : () => _reassign(context, card),
            ),
          ),
          SizedBox(height: spacing.xs),
        ],
      ],
    );
  }

  Future<void> _reassign(BuildContext context, PaymentCard card) async {
    final l10n = AppLocalizations.of(context)!;
    final target = await showCustomerPickerSheet(
      context: context,
      repository: viewModel.repository,
    );
    if (target == null || !context.mounted || target.id == card.customer) {
      return;
    }
    final ok = await viewModel.reassignCard(card.id, target.id);
    if (!context.mounted) {
      return;
    }
    _showSnack(
      context,
      ok ? l10n.cardReassignedMessage : l10n.cardReassignFailedMessage,
    );
  }
}

Future<String?> _promptCustomerName(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(l10n.nameCustomerTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: l10n.customerFullNameLabel),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(l10n.saveButton),
          ),
        ],
      );
    },
  );
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _CustomerProfile extends StatelessWidget {
  const _CustomerProfile({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final customer = viewModel.customer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (viewModel.hasCustomerError) ...[
          PointyInlineMessage.error(message: l10n.customerDetailsLoadError),
          SizedBox(height: spacing.sm),
        ],
        PointyMetricGrid(
          maxColumns: 2,
          minTileWidth: 200,
          gap: PointyMetricGridGap.compact,
          metrics: [
            PointyMetricGridItem(
              label: l10n.phoneOptionalLabel,
              value: _valueOrEmpty(l10n, customer.phone),
              icon: Icons.phone_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.emailOptionalLabel,
              value: _valueOrEmpty(l10n, customer.email),
              icon: Icons.alternate_email_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.genderLabel,
              value: genderLabel(l10n, customer.gender),
              icon: Icons.person_outline,
            ),
            PointyMetricGridItem(
              label: l10n.customerBirthdayLabel,
              value: customer.birthday == null
                  ? l10n.customerEmptyValue
                  : formatDate(customer.birthday!),
              icon: Icons.cake_outlined,
            ),
          ],
        ),
        if (customer.notes.trim().isNotEmpty) ...[
          SizedBox(height: spacing.md),
          _NotesBlock(label: l10n.customerNotesLabel, value: customer.notes),
        ],
      ],
    );
  }
}

class _CustomerSalesSummary extends StatelessWidget {
  const _CustomerSalesSummary({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final summary = viewModel.summary;

    if (viewModel.isLoadingSummary && summary.invoiceCount == 0) {
      return const PointyLoadingArea();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (viewModel.hasSummaryError) ...[
          PointyInlineMessage.error(
            message: l10n.customerSalesSummaryLoadError,
          ),
          SizedBox(height: spacing.sm),
        ],
        PointyMetricGrid(
          maxColumns: 3,
          minTileWidth: 170,
          gap: PointyMetricGridGap.compact,
          metrics: [
            PointyMetricGridItem(
              label: l10n.customerTotalInvoicedLabel,
              value: formatMoney(summary.totalInvoiced),
              icon: Icons.receipt_long_outlined,
              accentColor: colors.primaryStrong,
            ),
            PointyMetricGridItem(
              label: l10n.customerNetSalesLabel,
              value: formatMoney(summary.netSales),
              icon: Icons.payments_outlined,
              accentColor: colors.success,
            ),
            PointyMetricGridItem(
              label: l10n.customerOutstandingBalanceLabel,
              value: formatMoney(summary.outstandingBalance),
              icon: Icons.account_balance_wallet_outlined,
              accentColor: summary.outstandingBalance > 0.005
                  ? colors.danger
                  : null,
            ),
            PointyMetricGridItem(
              label: l10n.customerInvoiceCountLabel,
              value: summary.invoiceCount.toString(),
              icon: Icons.receipt_outlined,
              subtitle: l10n.customerPaidInvoiceCountValue(
                summary.paidInvoiceCount,
              ),
            ),
            PointyMetricGridItem(
              label: l10n.customerVoidCountLabel,
              value: summary.voidInvoiceCount.toString(),
              icon: Icons.block_outlined,
              accentColor: summary.voidInvoiceCount > 0 ? colors.warning : null,
              subtitle: formatMoney(summary.voidTotal),
            ),
            PointyMetricGridItem(
              label: l10n.customerReturnCountLabel,
              value: summary.returnCount.toString(),
              icon: Icons.keyboard_return_outlined,
              accentColor: summary.returnCount > 0 ? colors.warning : null,
              subtitle: formatMoney(summary.returnTotal),
            ),
            PointyMetricGridItem(
              label: l10n.customerRefundCountLabel,
              value: summary.refundCount.toString(),
              icon: Icons.currency_exchange_outlined,
              accentColor: summary.refundCount > 0 ? colors.warning : null,
              subtitle: formatMoney(summary.refundTotal),
            ),
            PointyMetricGridItem(
              label: l10n.customerExchangeCountLabel,
              value: summary.exchangeCount.toString(),
              icon: Icons.swap_horiz_outlined,
              subtitle: formatMoney(summary.exchangeTotal),
            ),
            if (summary.lastInvoiceAt != null)
              PointyMetricGridItem(
                label: l10n.customerLastInvoiceAtLabel,
                value: formatDateTime(summary.lastInvoiceAt!),
                icon: Icons.history_outlined,
              ),
          ],
        ),
      ],
    );
  }
}

class _CustomerInvoiceHistory extends StatelessWidget {
  const _CustomerInvoiceHistory({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingOrders && viewModel.orderHistory.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasOrderError && viewModel.orderHistory.isEmpty) {
      return PointyInlineMessage.error(
        message: l10n.customerInvoiceHistoryLoadError,
      );
    }
    if (viewModel.orderHistory.isEmpty) {
      return PointyEmptyState(
        icon: Icons.receipt_long_outlined,
        title: l10n.customerInvoiceHistoryEmpty,
      );
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.orderHistory.length,
        viewModel.hasMoreOrders,
      ),
      child: PointyDataList<SaleOrder>(
        items: viewModel.orderHistory,
        onLoadMore: viewModel.loadMoreOrderHistory,
        hasMore: viewModel.hasMoreOrders,
        isLoadingInitial: viewModel.isLoadingOrders,
        isLoadingMore: viewModel.isLoadingMoreOrders,
        emptyBuilder: (context) => PointyEmptyState(
          icon: Icons.receipt_long_outlined,
          title: l10n.customerInvoiceHistoryEmpty,
        ),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, order) {
          return PointyDataRow(
            leading: const Icon(Icons.receipt_long_outlined),
            title: l10n.saleReceiptTitle(
              order.receiptNumber ?? l10n.saleReceiptFallback,
            ),
            subtitle: [
              saleOrderStatusLabel(l10n, order.status),
              if (order.createdAt != null) formatDateTime(order.createdAt!),
              l10n.lineItemCount(order.lines.length),
              if (order.discountTotal > 0)
                l10n.discountLineValue(formatMoney(order.discountTotal)),
            ].join(' • '),
            trailing: Text(formatMoney(order.total)),
            onTap: () => showSaleOrderDetailsSheet(context, order),
          );
        },
      ),
    );
  }
}

class _CustomerAdjustmentHistory extends StatelessWidget {
  const _CustomerAdjustmentHistory({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingAdjustments && viewModel.adjustmentHistory.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasAdjustmentError && viewModel.adjustmentHistory.isEmpty) {
      return PointyInlineMessage.error(
        message: l10n.customerAdjustmentHistoryLoadError,
      );
    }
    if (viewModel.adjustmentHistory.isEmpty) {
      return PointyEmptyState(
        icon: Icons.assignment_return_outlined,
        title: l10n.customerAdjustmentHistoryEmpty,
      );
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.adjustmentHistory.length,
        viewModel.hasMoreAdjustments,
      ),
      child: PointyDataList<CustomerAdjustmentHistoryEntry>(
        items: viewModel.adjustmentHistory,
        onLoadMore: viewModel.loadMoreAdjustmentHistory,
        hasMore: viewModel.hasMoreAdjustments,
        isLoadingInitial: viewModel.isLoadingAdjustments,
        isLoadingMore: viewModel.isLoadingMoreAdjustments,
        emptyBuilder: (context) => PointyEmptyState(
          icon: Icons.assignment_return_outlined,
          title: l10n.customerAdjustmentHistoryEmpty,
        ),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, adjustment) {
          return PointyDataRow(
            leading: Icon(_adjustmentIcon(adjustment.type)),
            title: customerAdjustmentTypeLabel(l10n, adjustment.type),
            subtitle: [
              if (adjustment.receiptNumber.isNotEmpty)
                l10n.saleReceiptTitle(adjustment.receiptNumber),
              if (adjustment.createdAt != null)
                formatDateTime(adjustment.createdAt!),
              l10n.lineItemCount(adjustment.lines.length),
              l10n.customerRefundMethodValue(
                paymentMethodLabel(l10n, adjustment.refundMethod),
              ),
              if (adjustment.reason.isNotEmpty) adjustment.reason,
              if (adjustment.createdByUsername.isNotEmpty)
                l10n.customerAdjustmentCreatedByValue(
                  adjustment.createdByUsername,
                ),
            ].join(' • '),
            trailing: Text(formatMoney(adjustment.amount)),
          );
        },
      ),
    );
  }

  IconData _adjustmentIcon(CustomerAdjustmentType type) {
    return switch (type) {
      CustomerAdjustmentType.returnItems => Icons.keyboard_return_outlined,
      CustomerAdjustmentType.voidOrder => Icons.block_outlined,
      CustomerAdjustmentType.exchange => Icons.swap_horiz_outlined,
      CustomerAdjustmentType.refund => Icons.payments_outlined,
      CustomerAdjustmentType.unknown => Icons.assignment_return_outlined,
    };
  }
}

String saleOrderStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'paid' => l10n.saleOrderStatusPaid,
    'void' => l10n.saleOrderStatusVoid,
    'open' => l10n.saleOrderStatusOpen,
    _ => status,
  };
}

String customerAdjustmentTypeLabel(
  AppLocalizations l10n,
  CustomerAdjustmentType type,
) {
  return switch (type) {
    CustomerAdjustmentType.returnItems => l10n.customerAdjustmentTypeReturn,
    CustomerAdjustmentType.voidOrder => l10n.customerAdjustmentTypeVoid,
    CustomerAdjustmentType.exchange => l10n.customerAdjustmentTypeExchange,
    CustomerAdjustmentType.refund => l10n.customerAdjustmentTypeRefund,
    CustomerAdjustmentType.unknown => l10n.customerAdjustmentTypeUnknown,
  };
}

String _valueOrEmpty(AppLocalizations l10n, String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? l10n.customerEmptyValue : trimmed;
}

double _historyListHeight(int itemCount, bool hasMore) {
  if (hasMore || itemCount > 3) {
    return 248;
  }
  if (itemCount == 1) {
    return 80;
  }
  if (itemCount == 2) {
    return 160;
  }
  return 240;
}

class _NotesBlock extends StatelessWidget {
  const _NotesBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.line),
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.sticky_note_2_outlined,
                size: 16,
                color: colors.mutedInk,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: textTheme.labelMedium?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
          SizedBox(height: spacing.xs),
          Text(value, style: textTheme.bodyMedium),
        ],
      ),
    );
  }
}
