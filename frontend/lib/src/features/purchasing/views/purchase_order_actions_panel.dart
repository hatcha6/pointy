part of 'purchase_order_details_screen.dart';

class _PurchaseOrderActions extends StatelessWidget {
  const _PurchaseOrderActions({
    required this.viewModel,
    required this.printingRepository,
  });

  final PurchaseOrderDetailsViewModel viewModel;
  final PrintingRepository printingRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _Section(
      title: l10n.purchaseOrderActionsTitle,
      icon: Icons.tune_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (viewModel.hasStatusError) ...[
            Text(
              _statusErrorMessage(l10n, viewModel.statusError),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          if (viewModel.hasAdjustmentError) ...[
            Text(
              _adjustmentErrorMessage(l10n, viewModel.adjustmentError),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          if (viewModel.hasPaymentError) ...[
            Text(
              l10n.purchaseOrderPaymentError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          ResponsiveActionBar(
            compactBreakpoint: AppBreakpoints.largePhoneMin,
            expandActionsOnCompact: false,
            spacing: 8,
            runSpacing: 8,
            actions: [
              OutlinedButton.icon(
                onPressed: viewModel.isPrinting
                    ? null
                    : () => _printOrder(context),
                icon: viewModel.isPrinting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.print_outlined),
                label: Text(
                  viewModel.isPrinting
                      ? l10n.purchaseOrderPrintInProgressAction
                      : l10n.purchaseOrderPrintAction,
                ),
              ),
              OutlinedButton.icon(
                onPressed: viewModel.isSharing
                    ? null
                    : () => _shareOrder(context),
                icon: viewModel.isSharing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share_outlined),
                label: Text(
                  viewModel.isSharing
                      ? l10n.purchaseOrderShareInProgressAction
                      : l10n.purchaseOrderShareAction,
                ),
              ),
              OutlinedButton.icon(
                onPressed: viewModel.isPrinting || viewModel.isSharing
                    ? null
                    : () => _showPrintAudit(context),
                icon: const Icon(Icons.manage_search_outlined),
                label: Text(l10n.printAuditButton),
              ),
              if (viewModel.canRecordPayment)
                FilledButton.icon(
                  onPressed: viewModel.isRecordingPayment
                      ? null
                      : () => _showSupplierPaymentDialog(context),
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  label: Text(l10n.recordSupplierPaymentAction),
                ),
              if (viewModel.canSubmit)
                FilledButton.icon(
                  onPressed: viewModel.isChangingStatus
                      ? null
                      : () => _runAction(
                          context,
                          viewModel.submit,
                          l10n.purchaseOrderSubmitSuccess,
                        ),
                  icon: const Icon(Icons.send_outlined),
                  label: Text(l10n.submitPurchaseOrderAction),
                ),
              if (viewModel.canReceive)
                FilledButton.icon(
                  onPressed: viewModel.isChangingStatus
                      ? null
                      : () => _showReceivingDialog(context),
                  icon: const Icon(Icons.inventory_outlined),
                  label: Text(l10n.receivePurchaseLinesAction),
                ),
              if (viewModel.canCancel)
                OutlinedButton.icon(
                  onPressed: viewModel.isChangingStatus
                      ? null
                      : () => _runAction(
                          context,
                          viewModel.cancel,
                          l10n.purchaseOrderCancelSuccess,
                        ),
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(l10n.cancelButton),
                ),
              if (viewModel.canReturn)
                OutlinedButton.icon(
                  onPressed: viewModel.isAdjusting
                      ? null
                      : () => _showAdjustmentDialog(
                          context,
                          title: l10n.purchaseReturnTitle,
                          icon: Icons.keyboard_return_outlined,
                          action: viewModel.returnItems,
                          successMessage: l10n.purchaseReturnSuccess,
                        ),
                  icon: const Icon(Icons.keyboard_return_outlined),
                  label: Text(l10n.returnPurchaseItemsAction),
                ),
              if (viewModel.canRefund)
                OutlinedButton.icon(
                  onPressed: viewModel.isAdjusting
                      ? null
                      : () => _showAdjustmentDialog(
                          context,
                          title: l10n.purchaseRefundTitle,
                          icon: Icons.payments_outlined,
                          action: viewModel.refundItems,
                          successMessage: l10n.purchaseRefundSuccess,
                        ),
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(l10n.refundPurchaseItemsAction),
                ),
              if (viewModel.canExchange)
                OutlinedButton.icon(
                  onPressed: viewModel.isAdjusting
                      ? null
                      : () => _showExchangeDialog(context),
                  icon: const Icon(Icons.swap_horiz_outlined),
                  label: Text(l10n.exchangePurchaseItemsAction),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusErrorMessage(
    AppLocalizations l10n,
    PurchaseOrderActionError? error,
  ) {
    return switch (error) {
      PurchaseOrderActionError.permissionDenied =>
        l10n.purchaseOrderPermissionError,
      PurchaseOrderActionError.validationFailed =>
        l10n.purchaseOrderValidationError,
      PurchaseOrderActionError.receivedStockUnavailable ||
      PurchaseOrderActionError.generic ||
      null => l10n.purchaseOrderStatusChangeError,
    };
  }

  String _adjustmentErrorMessage(
    AppLocalizations l10n,
    PurchaseOrderActionError? error,
  ) {
    return switch (error) {
      PurchaseOrderActionError.receivedStockUnavailable =>
        l10n.purchaseOrderAdjustmentStockUnavailableError,
      PurchaseOrderActionError.permissionDenied =>
        l10n.purchaseOrderPermissionError,
      PurchaseOrderActionError.validationFailed =>
        l10n.purchaseOrderValidationError,
      PurchaseOrderActionError.generic ||
      null => l10n.purchaseOrderAdjustmentError,
    };
  }

  Future<void> _showSupplierPaymentDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_SupplierPaymentDialogResult>(
      context: context,
      builder: (context) => _SupplierPaymentDialog(order: viewModel.order),
    );
    if (result == null) {
      return;
    }

    final didRecord = await viewModel.recordPayment(
      method: result.method,
      amount: result.amount,
      reference: result.reference,
      notes: result.notes,
    );
    if (!context.mounted || !didRecord) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.supplierPaymentSuccess(viewModel.order.orderNumber),
          ),
        ),
      );
  }

  Future<void> _printOrder(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final didPrint = await viewModel.printOrder();
    if (!context.mounted) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            didPrint
                ? l10n.purchaseOrderPrintSuccess(viewModel.order.orderNumber)
                : l10n.purchaseOrderPrintError,
          ),
        ),
      );
  }

  Future<void> _shareOrder(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final status = await viewModel.shareOrder();
    if (!context.mounted || status == OrderDocumentActionStatus.canceled) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            status == OrderDocumentActionStatus.completed
                ? l10n.purchaseOrderShareSuccess(viewModel.order.orderNumber)
                : l10n.purchaseOrderShareError,
          ),
        ),
      );
  }

  Future<void> _showPrintAudit(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final order = viewModel.order;
    final documentNumber = order.orderNumber.isEmpty
        ? l10n.purchaseOrderFallbackTitle(order.id)
        : order.orderNumber;
    return showPrintAuditSheet(
      context: context,
      printingRepository: printingRepository,
      documentType: PrintAuditDocumentType.purchaseOrder,
      documentId: order.id,
      documentNumber: documentNumber,
    );
  }

  Future<void> _runAction(
    BuildContext context,
    Future<bool> Function() action,
    String Function(String orderNumber) message,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final didChange = await action();
    if (!context.mounted || !didChange) {
      return;
    }
    final orderNumber = viewModel.order.orderNumber;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message(orderNumber))));
  }

  Future<void> _showReceivingDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_PurchaseReceiveDialogResult>(
      context: context,
      builder: (context) => _PurchaseReceiveDialog(order: viewModel.order),
    );
    if (result == null) {
      return;
    }
    if (result.lines.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.purchaseReceiveNoItemsSelected)),
        );
      return;
    }

    final didReceive = await viewModel.receiveLines(
      lines: result.lines,
      note: result.note,
    );
    if (!context.mounted || !didReceive) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.purchaseOrderReceiveSuccess(viewModel.order.orderNumber),
          ),
        ),
      );
  }

  Future<void> _showAdjustmentDialog(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Future<bool> Function({
      required List<PurchaseAdjustmentLineDraft> lines,
      String reason,
    })
    action,
    required String Function(String orderNumber) successMessage,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_PurchaseAdjustmentDialogResult>(
      context: context,
      builder: (context) {
        return _PurchaseAdjustmentDialog(
          title: title,
          icon: icon,
          order: viewModel.order,
        );
      },
    );
    if (result == null) {
      return;
    }
    if (result.lines.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.purchaseAdjustmentNoItemsSelected)),
        );
      return;
    }

    final didAdjust = await action(lines: result.lines, reason: result.reason);
    if (!context.mounted || !didAdjust) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(successMessage(viewModel.order.orderNumber))),
      );
  }

  Future<void> _showExchangeDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_PurchaseExchangeDialogResult>(
      context: context,
      builder: (context) => _PurchaseExchangeDialog(order: viewModel.order),
    );
    if (result == null) {
      return;
    }
    if (result.lines.isEmpty || result.replacementLines.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.purchaseExchangeNoItemsSelected)),
        );
      return;
    }

    final didAdjust = await viewModel.exchangeItems(
      lines: result.lines,
      replacementLines: result.replacementLines,
      reason: result.reason,
    );
    if (!context.mounted || !didAdjust) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.purchaseExchangeSuccess(viewModel.order.orderNumber),
          ),
        ),
      );
  }
}
