part of 'shop_settings_screen.dart';

class _ShopIdentityFields extends StatelessWidget {
  const _ShopIdentityFields({
    required this.controller,
    required this.enabled,
    required this.errorText,
    required this.logoAttachment,
    required this.selectedLogoUpload,
    required this.hasLogoMarkedForRemoval,
    required this.onChanged,
    required this.onLogoSelected,
    required this.onLogoCleared,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final AttachmentSummary? logoAttachment;
  final ShopLogoUpload? selectedLogoUpload;
  final bool hasLogoMarkedForRemoval;
  final VoidCallback onChanged;
  final ValueChanged<ShopLogoUpload> onLogoSelected;
  final VoidCallback onLogoCleared;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ShopLogoField(
          logoAttachment: logoAttachment,
          selectedLogoUpload: selectedLogoUpload,
          hasLogoMarkedForRemoval: hasLogoMarkedForRemoval,
          enabled: enabled,
          onLogoSelected: onLogoSelected,
          onLogoCleared: onLogoCleared,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: controller,
          enabled: enabled,
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: l10n.shopNameLabel,
            errorText: errorText,
            prefixIcon: const Icon(Icons.storefront_outlined),
          ),
        ),
      ],
    );
  }
}

class _ShopLogoField extends StatelessWidget {
  const _ShopLogoField({
    required this.logoAttachment,
    required this.selectedLogoUpload,
    required this.hasLogoMarkedForRemoval,
    required this.enabled,
    required this.onLogoSelected,
    required this.onLogoCleared,
  });

  final AttachmentSummary? logoAttachment;
  final ShopLogoUpload? selectedLogoUpload;
  final bool hasLogoMarkedForRemoval;
  final bool enabled;
  final ValueChanged<ShopLogoUpload> onLogoSelected;
  final VoidCallback onLogoCleared;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final hasLogo =
        selectedLogoUpload != null ||
        (!hasLogoMarkedForRemoval && logoAttachment != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.shopLogoLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _ShopLogoPreview(
                  logoAttachment: logoAttachment,
                  selectedLogoUpload: selectedLogoUpload,
                  hasLogoMarkedForRemoval: hasLogoMarkedForRemoval,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasLogo
                            ? l10n.shopLogoUploadedValue
                            : l10n.shopLogoEmpty,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (selectedLogoUpload != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          selectedLogoUpload!.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      if (hasLogoMarkedForRemoval) ...[
                        const SizedBox(height: 4),
                        Text(
                          l10n.shopLogoMarkedForRemoval,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: enabled ? () => _pickLogo(context) : null,
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(
                hasLogo
                    ? l10n.shopLogoReplaceButton
                    : l10n.shopLogoUploadButton,
              ),
            ),
            if (hasLogo || hasLogoMarkedForRemoval)
              OutlinedButton.icon(
                onPressed: enabled ? onLogoCleared : null,
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.shopLogoRemoveButton),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickLogo(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
      withData: true,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.shopLogoPickError)));
      }
      return;
    }

    onLogoSelected(
      ShopLogoUpload(
        filename: file.name,
        bytes: bytes,
        contentType: _contentTypeForLogoFile(file),
      ),
    );
  }
}

class _ShopLogoPreview extends StatelessWidget {
  const _ShopLogoPreview({
    required this.logoAttachment,
    required this.selectedLogoUpload,
    required this.hasLogoMarkedForRemoval,
  });

  final AttachmentSummary? logoAttachment;
  final ShopLogoUpload? selectedLogoUpload;
  final bool hasLogoMarkedForRemoval;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    Widget child;
    if (selectedLogoUpload != null) {
      child = Image.memory(
        selectedLogoUpload!.bytes,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Icons.storefront_outlined, color: colors.primaryStrong),
      );
    } else if (!hasLogoMarkedForRemoval &&
        (logoAttachment?.contentUrl.trim().isNotEmpty ?? false)) {
      child = Image.network(
        logoAttachment!.contentUrl,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Icons.storefront_outlined, color: colors.primaryStrong),
      );
    } else {
      child = Icon(Icons.storefront_outlined, color: colors.primaryStrong);
    }

    return Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withOpacity(0.24),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

String _contentTypeForLogoFile(PlatformFile file) {
  final extension = (file.extension ?? '').toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    _ => 'image/jpeg',
  };
}

class _ReceiptSettingsFields extends StatelessWidget {
  const _ReceiptSettingsFields({
    required this.headerController,
    required this.footerController,
    required this.autoPrintReceipts,
    required this.enableOnlineInvoices,
    required this.enabled,
    required this.onAutoPrintReceiptsChanged,
    required this.onEnableOnlineInvoicesChanged,
  });

  final TextEditingController headerController;
  final TextEditingController footerController;
  final bool autoPrintReceipts;
  final bool enableOnlineInvoices;
  final bool enabled;
  final ValueChanged<bool> onAutoPrintReceiptsChanged;
  final ValueChanged<bool> onEnableOnlineInvoicesChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        TextFormField(
          controller: headerController,
          enabled: enabled,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: l10n.receiptHeaderLabel,
            prefixIcon: const Icon(Icons.notes_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: footerController,
          enabled: enabled,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: l10n.receiptFooterLabel,
            prefixIcon: const Icon(Icons.receipt_long_outlined),
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: autoPrintReceipts,
          title: Text(l10n.autoPrintReceiptsLabel),
          onChanged: enabled ? onAutoPrintReceiptsChanged : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enableOnlineInvoices,
          title: Text(l10n.enableOnlineInvoicesLabel),
          subtitle: Text(l10n.enableOnlineInvoicesSubtitle),
          onChanged: enabled ? onEnableOnlineInvoicesChanged : null,
        ),
      ],
    );
  }
}

class _RegisterSessionSettingsFields extends StatelessWidget {
  const _RegisterSessionSettingsFields({
    required this.requireOpeningCash,
    required this.enabled,
    required this.returnWindowText,
    required this.posCashPurchaseLimitController,
    required this.onRequireOpeningCashChanged,
    required this.onTap,
  });

  final bool requireOpeningCash;
  final bool enabled;
  final String returnWindowText;
  final TextEditingController posCashPurchaseLimitController;
  final ValueChanged<bool> onRequireOpeningCashChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: requireOpeningCash,
          title: Text(l10n.requireOpeningCashLabel),
          onChanged: enabled ? onRequireOpeningCashChanged : null,
        ),
        const SizedBox(height: 12),
        _DurationPickerTile(
          key: const ValueKey('cashier_return_window_picker'),
          enabled: enabled,
          label: l10n.cashierReturnWindowLabel,
          value: returnWindowText,
          onTap: onTap,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: posCashPurchaseLimitController,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [DecimalTextInputFormatter()],
          decoration: InputDecoration(
            labelText: l10n.posCashPurchaseLimitSettingLabel,
            helperText: l10n.posCashPurchaseLimitSettingHelp,
            helperMaxLines: 3,
            prefixIcon: const Icon(Icons.shopping_basket_outlined),
          ),
        ),
      ],
    );
  }
}

class _PaymentSettingsFields extends StatelessWidget {
  const _PaymentSettingsFields({
    required this.cardCommissionController,
    required this.transferCommissionController,
    required this.trustedTerminalIds,
    required this.enabled,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.requireCardPaymentReceipt,
    required this.requireCustomerForCredit,
    required this.allowCashierCustomerAccess,
    required this.paymentMethodsError,
    required this.cardCommissionError,
    required this.transferCommissionError,
    required this.onEnableCashChanged,
    required this.onEnableCardChanged,
    required this.onRequireCardReceiptChanged,
    required this.onRequireCustomerForCreditChanged,
    required this.onAllowCashierCustomerAccessChanged,
    required this.onEnableTransferChanged,
    required this.onCommissionChanged,
    required this.onManageTrustedTerminalIds,
  });

  final TextEditingController cardCommissionController;
  final TextEditingController transferCommissionController;
  final List<String> trustedTerminalIds;
  final bool enabled;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardPaymentReceipt;
  final bool requireCustomerForCredit;
  final bool allowCashierCustomerAccess;
  final String? paymentMethodsError;
  final String? cardCommissionError;
  final String? transferCommissionError;
  final ValueChanged<bool> onEnableCashChanged;
  final ValueChanged<bool> onEnableCardChanged;
  final ValueChanged<bool> onRequireCardReceiptChanged;
  final ValueChanged<bool> onRequireCustomerForCreditChanged;
  final ValueChanged<bool> onAllowCashierCustomerAccessChanged;
  final ValueChanged<bool> onEnableTransferChanged;
  final VoidCallback onCommissionChanged;
  final VoidCallback onManageTrustedTerminalIds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enableCashPayments,
          title: Text(l10n.paymentMethodCash),
          onChanged: enabled ? onEnableCashChanged : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enableCardPayments,
          title: Text(l10n.paymentMethodCard),
          onChanged: enabled ? onEnableCardChanged : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: requireCardPaymentReceipt,
          title: Text(l10n.requireCardReceiptSettingLabel),
          subtitle: Text(l10n.requireCardReceiptSettingSubtitle),
          onChanged: enabled && enableCardPayments
              ? onRequireCardReceiptChanged
              : null,
        ),
        const SizedBox(height: 8),
        _TrustedCardTerminalListField(
          terminalIds: trustedTerminalIds,
          enabled: enabled && enableCardPayments,
          onManage: onManageTrustedTerminalIds,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: cardCommissionController,
          enabled: enabled && enableCardPayments,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [DecimalTextInputFormatter()],
          onChanged: (_) => onCommissionChanged(),
          decoration: InputDecoration(
            labelText: l10n.cardCommissionPercentLabel,
            errorText: cardCommissionError,
            prefixIcon: const Icon(Icons.percent),
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enableTransferPayments,
          title: Text(l10n.paymentMethodTransfer),
          onChanged: enabled ? onEnableTransferChanged : null,
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: transferCommissionController,
          enabled: enabled && enableTransferPayments,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [DecimalTextInputFormatter()],
          onChanged: (_) => onCommissionChanged(),
          decoration: InputDecoration(
            labelText: l10n.transferCommissionPercentLabel,
            errorText: transferCommissionError,
            prefixIcon: const Icon(Icons.percent),
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          key: const ValueKey('require_customer_for_credit_switch'),
          contentPadding: EdgeInsets.zero,
          value: requireCustomerForCredit,
          title: Text(l10n.requireCustomerForCreditLabel),
          subtitle: Text(l10n.requireCustomerForCreditSubtitle),
          onChanged: enabled ? onRequireCustomerForCreditChanged : null,
        ),
        SwitchListTile(
          key: const ValueKey('allow_cashier_customer_access_switch'),
          contentPadding: EdgeInsets.zero,
          value: allowCashierCustomerAccess,
          title: Text(l10n.allowCashierCustomerAccessLabel),
          subtitle: Text(l10n.allowCashierCustomerAccessSubtitle),
          onChanged: enabled ? onAllowCashierCustomerAccessChanged : null,
        ),
        if (paymentMethodsError != null) ...[
          const SizedBox(height: 12),
          Text(
            paymentMethodsError!,
            style: TextStyle(color: context.pointyColors.danger),
          ),
        ],
      ],
    );
  }
}

class _TrustedCardTerminalListField extends StatelessWidget {
  const _TrustedCardTerminalListField({
    required this.terminalIds,
    required this.enabled,
    required this.onManage,
  });

  final List<String> terminalIds;
  final bool enabled;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final borderColor = enabled
        ? colors.line
        : colors.line.withOpacity(0.55);
    final foregroundColor = enabled ? colors.ink : colors.mutedInk;

    return DecoratedBox(
      key: const ValueKey('trusted_card_terminal_list_field'),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.point_of_sale_outlined, color: colors.primaryStrong),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.trustedCardTerminalIdsLabel,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foregroundColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.trustedCardTerminalIdsHelper,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  key: const ValueKey('manage_trusted_card_terminals_button'),
                  onPressed: enabled ? onManage : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.manageTrustedCardTerminalsButton),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (terminalIds.isEmpty)
              PointyInlineMessage(
                message: l10n.trustedCardTerminalAllowAnyMessage,
                icon: Icons.info_outline,
                compact: true,
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 156),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: terminalIds.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final terminalId = terminalIds[index];
                    return _TrustedCardTerminalListRow(terminalId: terminalId);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrustedCardTerminalListRow extends StatelessWidget {
  const _TrustedCardTerminalListRow({required this.terminalId});

  final String terminalId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withOpacity(0.38),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        child: Row(
          children: [
            Icon(
              Icons.confirmation_number_outlined,
              color: colors.mutedInk,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                terminalId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustedCardTerminalsDialog extends StatefulWidget {
  const _TrustedCardTerminalsDialog({required this.initialTerminalIds});

  final List<String> initialTerminalIds;

  @override
  State<_TrustedCardTerminalsDialog> createState() =>
      _TrustedCardTerminalsDialogState();
}

class _TrustedCardTerminalsDialogState
    extends State<_TrustedCardTerminalsDialog> {
  late final TextEditingController _terminalIdController;
  late List<String> _terminalIds;
  String? _terminalIdError;

  @override
  void initState() {
    super.initState();
    _terminalIdController = TextEditingController();
    _terminalIds = [...widget.initialTerminalIds]..sort();
  }

  @override
  void dispose() {
    _terminalIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.standard,
      child: AlertDialog(
        icon: const Icon(Icons.point_of_sale_outlined),
        title: Text(l10n.trustedCardTerminalsDialogTitle),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.trustedCardTerminalsDialogDescription),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 420;
                  final input = TextFormField(
                    key: const ValueKey('trusted_card_terminal_id_field'),
                    controller: _terminalIdController,
                    autofocus: true,
                    textDirection: TextDirection.ltr,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      if (_terminalIdError != null) {
                        setState(() => _terminalIdError = null);
                      }
                    },
                    onFieldSubmitted: (_) => _addTerminal(l10n),
                    decoration: InputDecoration(
                      labelText: l10n.trustedCardTerminalIdFieldLabel,
                      hintText: l10n.trustedCardTerminalIdFieldHint,
                      errorText: _terminalIdError,
                      prefixIcon: const Icon(Icons.badge_outlined),
                    ),
                  );
                  final addButton = FilledButton.tonalIcon(
                    key: const ValueKey('add_trusted_card_terminal_button'),
                    onPressed: () => _addTerminal(l10n),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.addTrustedCardTerminalButton),
                  );

                  if (isCompact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        input,
                        const SizedBox(height: 10),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: addButton,
                        ),
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: input),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: addButton,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              if (_terminalIds.isEmpty)
                PointyInlineMessage(
                  message: l10n.trustedCardTerminalAllowAnyMessage,
                  icon: Icons.info_outline,
                  compact: true,
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _terminalIds.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final terminalId = _terminalIds[index];
                      return _EditableTrustedCardTerminalRow(
                        terminalId: terminalId,
                        onRemove: () => _removeTerminal(terminalId),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: const ValueKey('trusted_card_terminals_done_button'),
            onPressed: () => Navigator.of(context).pop(_terminalIds),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
  }

  void _addTerminal(AppLocalizations l10n) {
    final terminalId = _normalizeTerminalId(_terminalIdController.text);
    if (terminalId.isEmpty) {
      setState(() => _terminalIdError = l10n.trustedCardTerminalRequiredError);
      return;
    }
    if (_terminalIds.contains(terminalId)) {
      setState(() => _terminalIdError = l10n.trustedCardTerminalDuplicateError);
      return;
    }

    setState(() {
      _terminalIds = [..._terminalIds, terminalId]..sort();
      _terminalIdError = null;
      _terminalIdController.clear();
    });
  }

  void _removeTerminal(String terminalId) {
    setState(() {
      _terminalIds = _terminalIds
          .where((currentTerminalId) => currentTerminalId != terminalId)
          .toList(growable: false);
    });
  }

  String _normalizeTerminalId(String value) => value.trim().toUpperCase();
}

class _EditableTrustedCardTerminalRow extends StatelessWidget {
  const _EditableTrustedCardTerminalRow({
    required this.terminalId,
    required this.onRemove,
  });

  final String terminalId;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: context.pointyColors.surfaceSunken.withOpacity(0.38),
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.confirmation_number_outlined),
        title: Text(
          terminalId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textDirection: TextDirection.ltr,
        ),
        trailing: IconButton(
          key: ValueKey('remove_trusted_card_terminal_$terminalId'),
          tooltip: l10n.removeTrustedCardTerminalTooltip(terminalId),
          onPressed: onRemove,
          icon: const Icon(Icons.delete_outline),
        ),
      ),
    );
  }
}

class _InventorySettingsFields extends StatelessWidget {
  const _InventorySettingsFields({
    required this.controller,
    required this.enabled,
    required this.errorText,
    required this.allowOverselling,
    required this.warnLowStockBeforeSale,
    required this.preventSellingAtLoss,
    required this.onThresholdChanged,
    required this.onAllowOversellingChanged,
    required this.onWarnLowStockBeforeSaleChanged,
    required this.onPreventSellingAtLossChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final bool allowOverselling;
  final bool warnLowStockBeforeSale;
  final bool preventSellingAtLoss;
  final VoidCallback onThresholdChanged;
  final ValueChanged<bool> onAllowOversellingChanged;
  final ValueChanged<bool> onWarnLowStockBeforeSaleChanged;
  final ValueChanged<bool> onPreventSellingAtLossChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        TextFormField(
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => onThresholdChanged(),
          decoration: InputDecoration(
            labelText: l10n.lowStockThresholdLabel,
            errorText: errorText,
            prefixIcon: const Icon(Icons.inventory_outlined),
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: allowOverselling,
          title: Text(l10n.allowOversellingLabel),
          onChanged: enabled ? onAllowOversellingChanged : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: warnLowStockBeforeSale,
          title: Text(l10n.warnLowStockBeforeSaleLabel),
          subtitle: Text(l10n.warnLowStockBeforeSaleSubtitle),
          onChanged: enabled ? onWarnLowStockBeforeSaleChanged : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: preventSellingAtLoss,
          title: Text(l10n.preventSellingAtLossLabel),
          subtitle: Text(l10n.preventSellingAtLossSubtitle),
          onChanged: enabled ? onPreventSellingAtLossChanged : null,
        ),
      ],
    );
  }
}

class _AnalyticsExportFields extends StatelessWidget {
  const _AnalyticsExportFields({
    required this.format,
    required this.occurredFrom,
    required this.occurredTo,
    required this.eventType,
    required this.severity,
    required this.source,
    required this.searchController,
    required this.platformController,
    required this.sessionController,
    required this.deviceController,
    required this.enabled,
    required this.onFormatChanged,
    required this.onEventTypeChanged,
    required this.onSeverityChanged,
    required this.onSourceChanged,
    required this.onTextFilterChanged,
    required this.onPickFrom,
    required this.onPickTo,
    required this.onClearDates,
  });

  final AnalyticsExportFormat format;
  final DateTime? occurredFrom;
  final DateTime? occurredTo;
  final String eventType;
  final String severity;
  final String source;
  final TextEditingController searchController;
  final TextEditingController platformController;
  final TextEditingController sessionController;
  final TextEditingController deviceController;
  final bool enabled;
  final ValueChanged<AnalyticsExportFormat> onFormatChanged;
  final ValueChanged<String> onEventTypeChanged;
  final ValueChanged<String> onSeverityChanged;
  final ValueChanged<String> onSourceChanged;
  final VoidCallback onTextFilterChanged;
  final VoidCallback onPickFrom;
  final VoidCallback onPickTo;
  final VoidCallback onClearDates;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        DropdownButtonFormField<AnalyticsExportFormat>(
          key: const ValueKey('analytics_export_format_field'),
          value: format,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportFormatLabel,
            prefixIcon: const Icon(Icons.table_chart_outlined),
          ),
          items: [
            DropdownMenuItem(
              value: AnalyticsExportFormat.csv,
              child: Text(l10n.analyticsExportFormatCsv),
            ),
            DropdownMenuItem(
              value: AnalyticsExportFormat.json,
              child: Text(l10n.analyticsExportFormatJson),
            ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value != null) {
                    onFormatChanged(value);
                  }
                }
              : null,
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final fromDate = _DateFilterTile(
              key: const ValueKey('analytics_export_from_date'),
              enabled: enabled,
              label: l10n.analyticsExportFromDateLabel,
              value: occurredFrom == null
                  ? l10n.analyticsExportOpenDateValue
                  : _formatAnalyticsDate(occurredFrom!),
              onTap: onPickFrom,
            );
            final toDate = _DateFilterTile(
              key: const ValueKey('analytics_export_to_date'),
              enabled: enabled,
              label: l10n.analyticsExportToDateLabel,
              value: occurredTo == null
                  ? l10n.analyticsExportOpenDateValue
                  : _formatAnalyticsDate(occurredTo!),
              onTap: onPickTo,
            );

            if (constraints.maxWidth < 520) {
              return Column(
                children: [fromDate, const SizedBox(height: 12), toDate],
              );
            }

            return Row(
              children: [
                Expanded(child: fromDate),
                const SizedBox(width: 12),
                Expanded(child: toDate),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: enabled ? onClearDates : null,
            icon: const Icon(Icons.clear_outlined),
            label: Text(l10n.analyticsExportClearDatesButton),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('analytics_export_event_type_field'),
          value: eventType,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportEventTypeLabel,
            prefixIcon: const Icon(Icons.category_outlined),
          ),
          items: [
            _analyticsOption(l10n.analyticsExportAnyValue, ''),
            for (final value in _analyticsEventTypes)
              _analyticsOption(_analyticsEventTypeLabel(l10n, value), value),
          ],
          onChanged: enabled
              ? (value) => onEventTypeChanged(value ?? '')
              : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('analytics_export_severity_field'),
          value: severity,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportSeverityLabel,
            prefixIcon: const Icon(Icons.priority_high_outlined),
          ),
          items: [
            _analyticsOption(l10n.analyticsExportAnyValue, ''),
            for (final value in _analyticsSeverities)
              _analyticsOption(_analyticsSeverityLabel(l10n, value), value),
          ],
          onChanged: enabled ? (value) => onSeverityChanged(value ?? '') : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('analytics_export_source_field'),
          value: source,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportSourceLabel,
            prefixIcon: const Icon(Icons.hub_outlined),
          ),
          items: [
            _analyticsOption(l10n.analyticsExportAnyValue, ''),
            for (final value in _analyticsSources)
              _analyticsOption(_analyticsSourceLabel(l10n, value), value),
          ],
          onChanged: enabled ? (value) => onSourceChanged(value ?? '') : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('analytics_export_search_field'),
          controller: searchController,
          enabled: enabled,
          onChanged: (_) => onTextFilterChanged(),
          decoration: InputDecoration(
            labelText: l10n.analyticsExportSearchLabel,
            prefixIcon: const Icon(Icons.search_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('analytics_export_platform_field'),
          controller: platformController,
          enabled: enabled,
          onChanged: (_) => onTextFilterChanged(),
          decoration: InputDecoration(
            labelText: l10n.analyticsExportPlatformLabel,
            prefixIcon: const Icon(Icons.devices_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('analytics_export_session_field'),
          controller: sessionController,
          enabled: enabled,
          onChanged: (_) => onTextFilterChanged(),
          decoration: InputDecoration(
            labelText: l10n.analyticsExportSessionLabel,
            prefixIcon: const Icon(Icons.confirmation_number_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('analytics_export_device_field'),
          controller: deviceController,
          enabled: enabled,
          onChanged: (_) => onTextFilterChanged(),
          decoration: InputDecoration(
            labelText: l10n.analyticsExportDeviceLabel,
            prefixIcon: const Icon(Icons.point_of_sale_outlined),
          ),
        ),
      ],
    );
  }
}

class _DateFilterTile extends StatelessWidget {
  const _DateFilterTile({
    super.key,
    required this.enabled,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final bool enabled;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.calendar_today_outlined),
          enabled: enabled,
        ),
        child: Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ),
    );
  }
}

class _DurationPickerTile extends StatelessWidget {
  const _DurationPickerTile({
    super.key,
    required this.enabled,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final bool enabled;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.schedule_outlined),
          suffixIcon: const Icon(Icons.expand_more),
          enabled: enabled,
        ),
        child: Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ),
    );
  }
}

class _SettingsSaveBar extends StatelessWidget {
  const _SettingsSaveBar({
    required this.isSaving,
    required this.hasSaveError,
    required this.onSubmit,
  });

  final bool isSaving;
  final bool hasSaveError;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return PointyStickyActionFooter(
      summary: hasSaveError
          ? Text(
              l10n.shopSettingsSaveError,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.danger),
            )
          : null,
      primaryAction: FilledButton.icon(
        onPressed: isSaving ? null : onSubmit,
        icon: isSaving
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.save_outlined),
        label: Text(isSaving ? l10n.savingButton : l10n.saveSettingsButton),
      ),
    );
  }
}

class _AnalyticsExportActionBar extends StatelessWidget {
  const _AnalyticsExportActionBar({
    required this.isExporting,
    required this.hasExportError,
    required this.onSubmit,
  });

  final bool isExporting;
  final bool hasExportError;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return PointyStickyActionFooter(
      summary: hasExportError
          ? Text(
              l10n.analyticsExportFailedMessage,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.danger),
            )
          : null,
      primaryAction: FilledButton.icon(
        key: const ValueKey('analytics_export_download_button'),
        onPressed: isExporting ? null : onSubmit,
        icon: isExporting
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.file_download_outlined),
        label: Text(
          isExporting
              ? l10n.analyticsExportRunningButton
              : l10n.analyticsExportDownloadButton,
        ),
      ),
    );
  }
}

DropdownMenuItem<String> _analyticsOption(String label, String value) {
  return DropdownMenuItem<String>(value: value, child: Text(label));
}

const _analyticsEventTypes = [
  'usage',
  'error',
  'performance',
  'security',
  'fraud_signal',
  'audit',
];

const _analyticsSeverities = ['debug', 'info', 'warning', 'error', 'critical'];

const _analyticsSources = ['frontend', 'backend', 'print_agent', 'integration'];

String _analyticsEventTypeLabel(AppLocalizations l10n, String value) {
  return switch (value) {
    'usage' => l10n.analyticsEventTypeUsage,
    'error' => l10n.analyticsEventTypeError,
    'performance' => l10n.analyticsEventTypePerformance,
    'security' => l10n.analyticsEventTypeSecurity,
    'fraud_signal' => l10n.analyticsEventTypeFraudSignal,
    'audit' => l10n.analyticsEventTypeAudit,
    _ => value,
  };
}

String _analyticsSeverityLabel(AppLocalizations l10n, String value) {
  return switch (value) {
    'debug' => l10n.analyticsSeverityDebug,
    'info' => l10n.analyticsSeverityInfo,
    'warning' => l10n.analyticsSeverityWarning,
    'error' => l10n.analyticsSeverityError,
    'critical' => l10n.analyticsSeverityCritical,
    _ => value,
  };
}

String _analyticsSourceLabel(AppLocalizations l10n, String value) {
  return switch (value) {
    'frontend' => l10n.analyticsSourceFrontend,
    'backend' => l10n.analyticsSourceBackend,
    'print_agent' => l10n.analyticsSourcePrintAgent,
    'integration' => l10n.analyticsSourceIntegration,
    _ => value,
  };
}

String _formatAnalyticsDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
