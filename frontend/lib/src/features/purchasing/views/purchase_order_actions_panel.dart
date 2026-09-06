part of 'purchase_order_details_screen.dart';

/// App-bar overflow menu for document utilities (print / share / audit) — kept
/// out of the workflow footer so they never compete with the next step.
class _PurchaseOrderDocumentMenu extends StatelessWidget {
  const _PurchaseOrderDocumentMenu({
    required this.viewModel,
    required this.printingRepository,
  });

  final PurchaseOrderDetailsViewModel viewModel;
  final PrintingRepository printingRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final busy = viewModel.isPrinting || viewModel.isSharing;

    return PopupMenuButton<_DocumentAction>(
      tooltip: l10n.purchaseOrderDocumentMenuTooltip,
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case _DocumentAction.print:
            _printPurchaseOrder(context, viewModel);
          case _DocumentAction.share:
            _sharePurchaseOrder(context, viewModel);
          case _DocumentAction.audit:
            _showPurchaseOrderPrintAudit(
              context,
              viewModel,
              printingRepository,
            );
          case _DocumentAction.trail:
            _showPurchaseOrderTrail(context, viewModel);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _DocumentAction.print,
          enabled: !busy,
          child: _DocumentMenuRow(
            icon: Icons.print_outlined,
            label: viewModel.isPrinting
                ? l10n.purchaseOrderPrintInProgressAction
                : l10n.purchaseOrderPrintAction,
          ),
        ),
        PopupMenuItem(
          value: _DocumentAction.share,
          enabled: !busy,
          child: _DocumentMenuRow(
            icon: Icons.ios_share_outlined,
            label: viewModel.isSharing
                ? l10n.purchaseOrderShareInProgressAction
                : l10n.purchaseOrderShareAction,
          ),
        ),
        PopupMenuItem(
          value: _DocumentAction.audit,
          enabled: !busy,
          child: _DocumentMenuRow(
            icon: Icons.manage_search_outlined,
            label: l10n.printAuditButton,
          ),
        ),
        // Only where the scope is installed: previews and tests that do not
        // wire it simply do not offer the item.
        if (DocumentTrailScope.maybeOf(context) != null)
          PopupMenuItem(
            value: _DocumentAction.trail,
            enabled: !busy,
            child: _DocumentMenuRow(
              icon: Icons.history_outlined,
              label: l10n.documentTrailOpenAction,
            ),
          ),
      ],
    );
  }
}

enum _DocumentAction { print, share, audit, trail }

class _DocumentMenuRow extends StatelessWidget {
  const _DocumentMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    );
  }
}

/// Inline error banners for failed status / adjustment / payment attempts,
/// surfaced near the top of the body now that the actions card is gone.
class _PurchaseOrderErrors extends StatelessWidget {
  const _PurchaseOrderErrors({required this.viewModel});

  final PurchaseOrderDetailsViewModel viewModel;

  static bool hasAny(PurchaseOrderDetailsViewModel viewModel) =>
      viewModel.hasStatusError ||
      viewModel.hasAdjustmentError ||
      viewModel.hasPaymentError;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final messages = <String>[
      if (viewModel.hasStatusError)
        _purchaseStatusErrorMessage(l10n, viewModel.statusError),
      if (viewModel.hasAdjustmentError)
        _purchaseAdjustmentErrorMessage(l10n, viewModel.adjustmentError),
      if (viewModel.hasPaymentError) l10n.purchaseOrderPaymentError,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, message) in messages.indexed) ...[
          if (index > 0) SizedBox(height: spacing.sm),
          PointyInlineMessage.error(message: message),
        ],
      ],
    );
  }
}

enum _PoActionStyle { normal, danger }

/// One purchase-order workflow action, carrying the context (label +
/// description) that the old bare icon row lacked.
class _PoAction {
  const _PoAction({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.style = _PoActionStyle.normal,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final String description;

  /// Null when the action is momentarily unavailable (a request is in flight).
  final VoidCallback? onTap;
  final _PoActionStyle style;
  final bool busy;
}

/// Pinned footer carrying one prominent, status-driven primary action and an
/// "other actions" menu where every remaining action is spelled out.
class _PurchaseOrderActionFooter extends StatelessWidget {
  const _PurchaseOrderActionFooter({required this.viewModel, this.onEdit});

  final PurchaseOrderDetailsViewModel viewModel;

  /// Opens the draft in the purchasing screen for editing. Null hides the
  /// action (no edit permission, or no editor wired in).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final statusBusy = viewModel.isChangingStatus;
    final adjustBusy = viewModel.isAdjusting;
    final payBusy = viewModel.isRecordingPayment;

    final submit = viewModel.canSubmit
        ? _PoAction(
            icon: Icons.send_outlined,
            label: l10n.submitPurchaseOrderAction,
            description: l10n.purchaseOrderSubmitDescription,
            busy: statusBusy,
            onTap: statusBusy
                ? null
                : () => _submitPurchaseOrder(context, viewModel),
          )
        : null;
    final edit = (viewModel.canEdit && onEdit != null)
        ? _PoAction(
            icon: Icons.edit_outlined,
            label: l10n.editPurchaseOrderAction,
            description: l10n.purchaseOrderEditDescription,
            onTap: statusBusy ? null : onEdit,
          )
        : null;
    final receive = viewModel.canReceive
        ? _PoAction(
            icon: Icons.inventory_outlined,
            label: l10n.receivePurchaseLinesAction,
            description: l10n.purchaseOrderReceiveDescription,
            busy: statusBusy,
            onTap: statusBusy
                ? null
                : () => _showReceivingDialog(context, viewModel),
          )
        : null;
    final pay = viewModel.canRecordPayment
        ? _PoAction(
            icon: Icons.account_balance_wallet_outlined,
            label: l10n.recordSupplierPaymentAction,
            description: l10n.purchaseOrderRecordPaymentDescription,
            busy: payBusy,
            onTap: payBusy
                ? null
                : () => _showSupplierPaymentDialog(context, viewModel),
          )
        : null;
    final returnItems = viewModel.canReturn
        ? _PoAction(
            icon: Icons.keyboard_return_outlined,
            label: l10n.returnPurchaseItemsAction,
            description: l10n.purchaseOrderReturnDescription,
            busy: adjustBusy,
            onTap: adjustBusy
                ? null
                : () => _returnPurchaseItems(context, viewModel),
          )
        : null;
    final refund = viewModel.canRefund
        ? _PoAction(
            icon: Icons.payments_outlined,
            label: l10n.refundPurchaseItemsAction,
            description: l10n.purchaseOrderRefundDescription,
            busy: adjustBusy,
            onTap: adjustBusy
                ? null
                : () => _refundPurchaseItems(context, viewModel),
          )
        : null;
    final exchange = viewModel.canExchange
        ? _PoAction(
            icon: Icons.swap_horiz_outlined,
            label: l10n.exchangePurchaseItemsAction,
            description: l10n.purchaseOrderExchangeDescription,
            busy: adjustBusy,
            onTap: adjustBusy
                ? null
                : () => _showExchangeDialog(context, viewModel),
          )
        : null;
    final cancel = viewModel.canCancel
        ? _PoAction(
            icon: Icons.cancel_outlined,
            label: l10n.cancelButton,
            description: l10n.purchaseOrderCancelActionDescription,
            style: _PoActionStyle.danger,
            busy: statusBusy,
            onTap: statusBusy
                ? null
                : () => _cancelPurchaseOrder(context, viewModel),
          )
        : null;

    final primary = submit ?? receive ?? pay;
    final extras = <_PoAction>[
      if (pay != null && !identical(pay, primary)) pay,
      ?returnItems,
      ?refund,
      ?exchange,
      ?cancel,
    ];

    if (primary == null && extras.isEmpty && edit == null) {
      return const SizedBox.shrink();
    }

    final summary = _footerSummary(context, viewModel.order);

    Widget moreButton({required bool filled}) {
      final icon = const Icon(Icons.more_horiz);
      final label = Text(l10n.purchaseOrderMoreActionsLabel);
      void onPressed() => _showPurchaseOrderActionSheet(
        context,
        actions: extras,
        title: l10n.purchaseOrderActionsSheetTitle,
      );
      return filled
          ? FilledButton.tonalIcon(
              onPressed: onPressed,
              icon: icon,
              label: label,
            )
          : OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label);
    }

    // For a draft, Send is the primary "next step" and Edit sits beside it as a
    // visible secondary — corrections (e.g. Cancel) stay in the overflow sheet.
    final editButton = edit == null
        ? null
        : _secondaryActionButton(context, edit);

    if (primary != null) {
      return PointyStickyActionFooter(
        summary: summary,
        secondaryActions: [
          ?editButton,
          if (extras.isNotEmpty) moreButton(filled: false),
        ],
        primaryAction: _primaryActionButton(context, primary),
      );
    }

    // No status-driven primary. Edit leads when it's the only action available.
    if (edit != null) {
      return PointyStickyActionFooter(
        summary: summary,
        secondaryActions: [if (extras.isNotEmpty) moreButton(filled: false)],
        primaryAction: _primaryActionButton(context, edit),
      );
    }

    // No status-driven primary, but corrections remain available.
    return PointyStickyActionFooter(
      summary: summary,
      primaryAction: extras.length == 1
          ? _primaryActionButton(context, extras.first)
          : moreButton(filled: true),
    );
  }
}

Widget _secondaryActionButton(BuildContext context, _PoAction action) {
  return OutlinedButton.icon(
    onPressed: action.onTap,
    icon: Icon(action.icon),
    label: Text(action.label),
  );
}

Widget _primaryActionButton(BuildContext context, _PoAction action) {
  final colors = context.pointyColors;
  final icon = action.busy
      ? const SizedBox.square(
          dimension: 18,
          child: PointySpinner(strokeWidth: 2),
        )
      : Icon(action.icon);
  final label = Text(action.label);

  if (action.style == _PoActionStyle.danger) {
    return OutlinedButton.icon(
      onPressed: action.onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.danger,
        side: BorderSide(color: colors.danger.withValues(alpha: 0.5)),
      ),
      icon: icon,
      label: label,
    );
  }
  return FilledButton.icon(onPressed: action.onTap, icon: icon, label: label);
}

Widget? _footerSummary(BuildContext context, PurchaseOrder order) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  final textTheme = Theme.of(context).textTheme;

  if (order.balanceDue > 0.005) {
    final valueStyle = textTheme.titleMedium?.copyWith(
      color: order.isOverdue ? colors.danger : colors.ink,
      fontWeight: FontWeight.w800,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.purchaseOrderBalanceDueLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        Text(
          formatMoney(order.balanceDue),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: valueStyle == null
              ? null
              : PointyTypography.numeric(valueStyle),
        ),
      ],
    );
  }

  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        _purchaseOrderStatusIcon(order.status),
        size: 18,
        color: _purchaseOrderStatusColor(colors, order.status),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          purchaseOrderStatusLabel(l10n, order.status),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleSmall?.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

Future<void> _showPurchaseOrderActionSheet(
  BuildContext context, {
  required List<_PoAction> actions,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final spacing = AdaptiveSpacing.of(sheetContext);
      // Scrollable so a tall action list (or a tight viewport) never overflows
      // the sheet — it just scrolls.
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  spacing.lg,
                  spacing.xs,
                  spacing.lg,
                  spacing.sm,
                ),
                child: Text(
                  title,
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              for (final action in actions)
                _PurchaseOrderActionTile(
                  action: action,
                  onInvoke: () {
                    Navigator.of(sheetContext).pop();
                    action.onTap?.call();
                  },
                ),
              SizedBox(height: spacing.sm),
            ],
          ),
        ),
      );
    },
  );
}

class _PurchaseOrderActionTile extends StatelessWidget {
  const _PurchaseOrderActionTile({
    required this.action,
    required this.onInvoke,
  });

  final _PoAction action;
  final VoidCallback onInvoke;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final accent = action.style == _PoActionStyle.danger
        ? colors.danger
        : colors.primaryStrong;

    return ListTile(
      enabled: action.onTap != null,
      onTap: onInvoke,
      leading: CircleAvatar(
        backgroundColor: accent.withValues(alpha: 0.12),
        foregroundColor: accent,
        child: Icon(action.icon),
      ),
      title: Text(
        action.label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: action.style == _PoActionStyle.danger
              ? colors.danger
              : colors.ink,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        action.description,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Action handlers (shared by the footer, its action sheet and the app-bar menu)
// ---------------------------------------------------------------------------

Future<void> _submitPurchaseOrder(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => PointyConfirmationDialog(
      icon: Icons.send_outlined,
      title: l10n.submitPurchaseOrderConfirmTitle,
      message: l10n.submitPurchaseOrderConfirmMessage,
      confirmLabel: l10n.submitPurchaseOrderAction,
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runPurchaseStatusAction(
      context,
      viewModel,
      viewModel.submit,
      l10n.purchaseOrderSubmitSuccess,
    );
  }
}

Future<void> _cancelPurchaseOrder(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => PointyDestructiveConfirmationDialog(
      icon: Icons.cancel_outlined,
      title: l10n.cancelPurchaseOrderConfirmTitle,
      message: l10n.cancelPurchaseOrderConfirmMessage,
      confirmLabel: l10n.cancelPurchaseOrderConfirmButton,
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runPurchaseStatusAction(
      context,
      viewModel,
      viewModel.cancel,
      l10n.purchaseOrderCancelSuccess,
    );
  }
}

Future<void> _runPurchaseStatusAction(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
  Future<bool> Function() action,
  String Function(String orderNumber) message,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final didChange = await action();
  if (!context.mounted || !didChange) {
    return;
  }
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(content: Text(message(viewModel.order.orderNumber))),
    );
}

Future<void> _returnPurchaseItems(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) {
  final l10n = AppLocalizations.of(context)!;
  return _showPurchaseAdjustmentDialog(
    context,
    viewModel,
    title: l10n.purchaseReturnTitle,
    icon: Icons.keyboard_return_outlined,
    action: viewModel.returnItems,
    successMessage: l10n.purchaseReturnSuccess,
  );
}

Future<void> _refundPurchaseItems(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) {
  final l10n = AppLocalizations.of(context)!;
  return _showPurchaseAdjustmentDialog(
    context,
    viewModel,
    title: l10n.purchaseRefundTitle,
    icon: Icons.payments_outlined,
    action: viewModel.refundItems,
    successMessage: l10n.purchaseRefundSuccess,
  );
}

Future<void> _showSupplierPaymentDialog(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final result = await showRecordPaymentDialog(
    context,
    title: l10n.supplierPaymentTitle,
    maxAmount: viewModel.order.balanceDue,
    methods: supplierPaymentMethodOptions(l10n),
    showReference: true,
    showNotes: true,
    proofToggleLabel: l10n.supplierPaymentPrintProofLabel,
  );
  if (result == null) {
    return;
  }

  final didRecord = await viewModel.recordPayment(
    method: SupplierPaymentMethod.fromApiValue(result.methodApiValue),
    amount: result.amount,
    reference: result.reference,
    notes: result.notes,
    printProof: result.printProof,
  );
  if (!context.mounted || !didRecord) {
    return;
  }
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(l10n.supplierPaymentSuccess(viewModel.order.orderNumber)),
      ),
    );
}

Future<void> _printPurchaseOrder(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) async {
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

Future<void> _sharePurchaseOrder(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) async {
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

Future<void> _showPurchaseOrderPrintAudit(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
  PrintingRepository printingRepository,
) {
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

Future<void> _showPurchaseOrderTrail(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) {
  final repository = DocumentTrailScope.maybeOf(context);
  if (repository == null) {
    return Future<void>.value();
  }
  final l10n = AppLocalizations.of(context)!;
  final order = viewModel.order;
  return showDocumentTrailSheet(
    context: context,
    repository: repository,
    documentType: 'purchase_order',
    documentId: order.id,
    documentNumber: order.orderNumber.isEmpty
        ? l10n.purchaseOrderFallbackTitle(order.id)
        : order.orderNumber,
  );
}

Future<void> _showReceivingDialog(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) async {
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

Future<void> _showPurchaseAdjustmentDialog(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel, {
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
  final result = await showQuantityAdjustmentDialog(
    context,
    icon: icon,
    title: title,
    emptyMessage: l10n.purchaseNoAdjustableItems,
    reasonLabel: l10n.purchaseAdjustmentReasonLabel,
    reasonHint: l10n.purchaseAdjustmentReasonHint,
    options: _purchaseAdjustmentOptions(l10n, viewModel.order),
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

  final didAdjust = await action(
    lines: _purchaseAdjustmentDrafts(result.lines),
    reason: result.reason,
  );
  if (!context.mounted || !didAdjust) {
    return;
  }
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(content: Text(successMessage(viewModel.order.orderNumber))),
    );
}

Future<void> _showExchangeDialog(
  BuildContext context,
  PurchaseOrderDetailsViewModel viewModel,
) async {
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

String _purchaseStatusErrorMessage(
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

String _purchaseAdjustmentErrorMessage(
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
