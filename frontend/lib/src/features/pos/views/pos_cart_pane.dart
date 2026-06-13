import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/pos_view_model.dart';
import '../../../data/models/cart_line.dart';
import 'cart_line_tile.dart';
import 'weight_entry_sheet.dart';
import 'cart_totals.dart';
import 'payment/payment.dart';
import 'pos_sale_session_strip.dart';
import 'public_invoice_dialog.dart';

class PosCartPane extends StatelessWidget {
  const PosCartPane({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    this.onCheckoutSuccess,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onCheckoutSuccess;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        final isCartLocked = viewModel.isCheckingOut || !canCheckout;
        final spacing = AdaptiveSpacing.of(context);
        final colors = context.pointyColors;

        return ColoredBox(
          color: colors.page,
          child: Padding(
            padding: spacing.compactPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: PointyOrderPanel(
                    title: l10n.currentSaleTitle,
                    subtitle: _saleDraftSubtitle(l10n, viewModel),
                    trailing: _PosCartHeaderActions(
                      viewModel: viewModel,
                      isCartLocked: isCartLocked,
                      onEditSettings: () => _showSaleSettingsDialog(context),
                    ),
                    child: _CartScrollContent(
                      viewModel: viewModel,
                      isCartLocked: isCartLocked,
                    ),
                  ),
                ),
                SizedBox(height: spacing.sm),
                _CheckoutFooter(
                  viewModel: viewModel,
                  capabilities: capabilities,
                  onCheckout: () => _checkout(context),
                ),
              ],
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
    final lossLines = viewModel.checkoutLossLines();
    if (lossLines.isNotEmpty) {
      final shouldContinue = await _showLossWarningDialog(
        context,
        lossLines: lossLines,
        canSellAtLoss: !viewModel.preventSellingAtLoss,
      );
      if (shouldContinue != true) {
        return;
      }
      if (!context.mounted) {
        return;
      }
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
    if (outcome.isLossRejected) {
      await _showLossWarningDialog(
        context,
        lossLines: outcome.lossLines,
        canSellAtLoss: false,
      );
      return;
    }
    if (outcome.isSessionExpired) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.saleCheckoutSessionExpired)),
        );
      return;
    }

    final receiptNumber = outcome.order?.receiptNumber;
    var message = outcome.isSuccess
        ? receiptNumber == null || receiptNumber.isEmpty
              ? l10n.saleCheckoutSuccess
              : l10n.saleCheckoutSuccessWithReceipt(receiptNumber)
        : l10n.saleCheckoutError;
    if (outcome.isSuccess && payment.shareInvoiceAfterPayment) {
      final order = outcome.order;
      final shareStatus = order == null
          ? OrderDocumentActionStatus.failed
          : await viewModel.sharePaidInvoice(order);
      if (!context.mounted) {
        return;
      }
      message = switch (shareStatus) {
        OrderDocumentActionStatus.completed =>
          '$message ${l10n.invoiceShareSuccess}',
        OrderDocumentActionStatus.failed =>
          '$message ${l10n.invoiceShareError}',
        OrderDocumentActionStatus.canceled => message,
      };
    }

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

    if (outcome.isSuccess) {
      final order = outcome.order;
      if (order != null && order.publicInvoiceUrl.trim().isNotEmpty) {
        await showPublicInvoiceDialog(context: context, order: order);
        if (!context.mounted) {
          return;
        }
      }
      onCheckoutSuccess?.call();
    }
  }

  Future<void> _showSaleSettingsDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => _SaleSettingsDialog(
        viewModel: viewModel,
        contactRepository: contactRepository,
      ),
    );
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
                        formatSaleQuantity(shortage.requested),
                        formatSaleQuantity(shortage.available),
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

  Future<bool?> _showLossWarningDialog(
    BuildContext context, {
    required List<SaleLossLine> lossLines,
    required bool canSellAtLoss,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.warning_amber_outlined),
          title: Text(l10n.lossSaleWarningTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  canSellAtLoss
                      ? l10n.lossSaleWarningMessage
                      : l10n.lossSaleBlockedMessage,
                ),
                const SizedBox(height: 12),
                for (final line in lossLines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      l10n.lossSaleLine(
                        line.productName,
                        formatMoney(line.lossAmount),
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
                canSellAtLoss ? l10n.cancelButton : l10n.reviewCartButton,
              ),
            ),
            if (canSellAtLoss)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.continueSaleButton),
              ),
          ],
        );
      },
    );
  }

  Future<PaymentSheetResult?> _showPaymentDialog(BuildContext context) {
    return showPosPaymentSheet(
      context: context,
      total: viewModel.total,
      enableCashPayments: viewModel.enableCashPayments,
      enableCardPayments: viewModel.enableCardPayments,
      enableTransferPayments: viewModel.enableTransferPayments,
      requireCardReceipt: viewModel.requireCardPaymentReceipt,
      trustedCardTerminalIds: viewModel.trustedCardTerminalIds,
      showPrintInvoiceToggle: viewModel.shouldShowPrintInvoiceCheckbox,
      printInvoiceAfterPayment: viewModel.printInvoiceAfterPayment,
      onPrintInvoiceChanged: viewModel.updatePrintInvoiceAfterPayment,
      showShareInvoiceToggle: viewModel.shouldShowShareInvoiceCheckbox,
      shareInvoiceAfterPayment: viewModel.shareInvoiceAfterPayment,
      onShareInvoiceChanged: viewModel.updateShareInvoiceAfterPayment,
    );
  }
}

String _saleDraftSubtitle(AppLocalizations l10n, PosViewModel viewModel) {
  final customerName = viewModel.selectedCustomer?.fullName.trim();
  if (customerName != null && customerName.isNotEmpty) {
    return customerName;
  }
  return l10n.walkInCustomerLabel;
}

class _CartScrollContent extends StatelessWidget {
  const _CartScrollContent({
    required this.viewModel,
    required this.isCartLocked,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final visibleLines = viewModel.cart.reversed.toList(growable: false);

    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.md,
        spacing.md,
      ),
      children: [
        Divider(height: 1, color: colors.line),
        if (viewModel.cart.isEmpty)
          SizedBox(
            height: 220,
            child: PointyEmptyState(
              icon: Icons.shopping_cart_outlined,
              title: l10n.emptyCart,
            ),
          )
        else
          for (var index = 0; index < visibleLines.length; index += 1) ...[
            if (index > 0) Divider(height: 1, color: colors.line),
            CartLineTile(
              line: visibleLines[index],
              onAdd: isCartLocked
                  ? null
                  : () => viewModel.addVariant(
                      visibleLines[index].variant,
                      source: 'cart_quantity_button',
                    ),
              onRemove: isCartLocked
                  ? null
                  : () => viewModel.decrementVariant(
                      visibleLines[index].variant,
                      source: 'cart_quantity_button',
                    ),
              onDelete: isCartLocked
                  ? null
                  : () => viewModel.removeVariant(
                      visibleLines[index].variant,
                      source: 'cart_delete_button',
                    ),
              onEditQuantity: isCartLocked
                  ? null
                  : () => _editLineWeight(context, visibleLines[index]),
            ),
          ],
      ],
    );
  }
  Future<void> _editLineWeight(BuildContext context, CartLine line) async {
    final weight = await showWeightEntrySheet(
      context,
      variant: line.variant,
      initialQuantity: line.quantity,
    );
    if (weight != null && context.mounted) {
      viewModel.setVariantQuantity(line.variant, weight);
    }
  }
}

class _PosCartHeaderActions extends StatelessWidget {
  const _PosCartHeaderActions({
    required this.viewModel,
    required this.isCartLocked,
    required this.onEditSettings,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;
  final VoidCallback onEditSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final couponCode = viewModel.couponCode.trim();
    final hasCoupon = couponCode.isNotEmpty;
    final hasIssue =
        viewModel.hasDiscountPreviewError ||
        viewModel.unappliedCouponCodes.isNotEmpty;
    final hasActiveSettings =
        viewModel.selectedCustomer != null ||
        hasCoupon ||
        viewModel.appliedDiscounts.isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PosSaleSessionSwitcher(
          sessions: viewModel.saleSessions,
          canStartNewSession: viewModel.canStartNewSaleSession && !isCartLocked,
          isLocked: isCartLocked,
          onStartNewSession: viewModel.startNewSaleSession,
          onSelectSession: viewModel.switchSaleSession,
          onDiscardSession: viewModel.discardSaleSession,
        ),
        IconButton(
          key: const ValueKey('sale_draft_settings_button'),
          tooltip: l10n.saleDraftSettingsActionTooltip,
          onPressed: isCartLocked ? null : onEditSettings,
          icon: const Icon(Icons.tune),
          color: hasIssue
              ? colors.danger
              : hasActiveSettings
              ? colors.primaryStrong
              : null,
        ),
        IconButton(
          tooltip: l10n.clearCartTooltip,
          onPressed: viewModel.cart.isEmpty || isCartLocked
              ? null
              : viewModel.clearCart,
          icon: const Icon(Icons.delete_outline),
          color: colors.danger,
        ),
      ],
    );
  }
}

class _SaleSettingsDialog extends StatefulWidget {
  const _SaleSettingsDialog({
    required this.viewModel,
    required this.contactRepository,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;

  @override
  State<_SaleSettingsDialog> createState() => _SaleSettingsDialogState();
}

class _SaleSettingsDialogState extends State<_SaleSettingsDialog> {
  late var _selectedCustomer = widget.viewModel.selectedCustomer;
  late final TextEditingController _controller = TextEditingController(
    text: widget.viewModel.couponCode,
  );

  String get _currentCode => _controller.text.trim();

  bool get _matchesSavedCode =>
      _currentCode == widget.viewModel.couponCode.trim();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasCoupon = _currentCode.isNotEmpty;
    final hasInvalidCoupon =
        _matchesSavedCode && widget.viewModel.unappliedCouponCodes.isNotEmpty;

    return AlertDialog(
      icon: const Icon(Icons.tune),
      title: Text(l10n.saleDraftSettingsDialogTitle),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ContactSelectionTile(
                label: l10n.selectedCustomerLabel,
                value: _selectedCustomer?.fullName ?? '',
                placeholder: l10n.walkInCustomerLabel,
                icon: Icons.person_pin_circle_outlined,
                enabled: !widget.viewModel.isCheckingOut,
                onSelect: _selectCustomer,
                onClear: () => setState(() => _selectedCustomer = null),
                allowClear: _selectedCustomer != null,
                selectActionIcon: Icons.edit_outlined,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                enabled: !widget.viewModel.isCheckingOut,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: l10n.discountCouponCodeLabel,
                  hintText: l10n.discountCouponCodeHint,
                  isDense: true,
                  prefixIcon: const Icon(Icons.confirmation_number_outlined),
                  errorText: hasInvalidCoupon
                      ? l10n.discountCouponUnavailable(
                          widget.viewModel.unappliedCouponCodes.join('، '),
                        )
                      : _matchesSavedCode &&
                            widget.viewModel.hasDiscountPreviewError
                      ? l10n.discountPreviewUnavailable
                      : null,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _apply(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        if (hasCoupon)
          TextButton(
            onPressed: _clear,
            child: Text(l10n.clearCouponCodeTooltip),
          ),
        TextButton(
          onPressed: _refresh,
          child: Text(l10n.refreshDiscountPreviewTooltip),
        ),
        FilledButton(onPressed: _apply, child: Text(l10n.saveButton)),
      ],
    );
  }

  Future<void> _selectCustomer() async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (customer == null || !mounted) {
      return;
    }
    setState(() => _selectedCustomer = customer);
  }

  void _apply() {
    _saveSettings();
    Navigator.of(context).pop();
  }

  void _clear() {
    _controller.clear();
    _saveSettings();
    Navigator.of(context).pop();
  }

  void _refresh() {
    final customerChanged =
        _selectedCustomer?.id != widget.viewModel.selectedCustomer?.id;
    final codeChanged = _currentCode != widget.viewModel.couponCode.trim();
    _saveSettings();
    if (!customerChanged && !codeChanged) {
      unawaited(widget.viewModel.refreshDiscountPreview());
    }
    Navigator.of(context).pop();
  }

  void _saveSettings() {
    if (_selectedCustomer?.id != widget.viewModel.selectedCustomer?.id) {
      widget.viewModel.selectCustomer(_selectedCustomer);
    }
    if (_currentCode != widget.viewModel.couponCode.trim()) {
      widget.viewModel.updateCouponCode(_currentCode);
    }
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
    final spacing = AdaptiveSpacing.of(context);
    final canSubmit = viewModel.cart.isNotEmpty && !viewModel.isCheckingOut;

    return PointyStickyActionFooter(
      padding: EdgeInsetsDirectional.fromSTEB(spacing.sm, 6, spacing.sm, 6),
      primaryActionHeight: 52,
      summary: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CartTotals(viewModel: viewModel, compact: true),
          if (viewModel.shouldShowPrintInvoiceCheckbox)
            InkWell(
              onTap: viewModel.isCheckingOut
                  ? null
                  : () => viewModel.updatePrintInvoiceAfterPayment(
                      !viewModel.printInvoiceAfterPayment,
                    ),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(top: 2),
                child: Row(
                  children: [
                    Checkbox(
                      value: viewModel.printInvoiceAfterPayment,
                      onChanged: viewModel.isCheckingOut
                          ? null
                          : (value) => viewModel.updatePrintInvoiceAfterPayment(
                              value ?? false,
                            ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        l10n.printInvoiceAfterPaymentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      primaryAction: CheckoutGuard(
        capabilities: capabilities,
        child: FilledButton.icon(
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
    );
  }
}
