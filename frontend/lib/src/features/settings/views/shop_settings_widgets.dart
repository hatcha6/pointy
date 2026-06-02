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
            border: const OutlineInputBorder(),
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
    final colorScheme = theme.colorScheme;
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
            border: Border.all(color: colorScheme.outlineVariant),
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
                            color: colorScheme.error,
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
    final result = await FilePicker.pickFiles(
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
    final colorScheme = Theme.of(context).colorScheme;

    Widget child;
    if (selectedLogoUpload != null) {
      child = Image.memory(
        selectedLogoUpload!.bytes,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Icons.storefront_outlined, color: colorScheme.primary),
      );
    } else if (!hasLogoMarkedForRemoval &&
        (logoAttachment?.contentUrl.trim().isNotEmpty ?? false)) {
      child = Image.network(
        logoAttachment!.contentUrl,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Icons.storefront_outlined, color: colorScheme.primary),
      );
    } else {
      child = Icon(Icons.storefront_outlined, color: colorScheme.primary);
    }

    return Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.24),
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
    required this.enabled,
    required this.onAutoPrintReceiptsChanged,
  });

  final TextEditingController headerController;
  final TextEditingController footerController;
  final bool autoPrintReceipts;
  final bool enabled;
  final ValueChanged<bool> onAutoPrintReceiptsChanged;

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
            border: const OutlineInputBorder(),
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
            border: const OutlineInputBorder(),
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
      ],
    );
  }
}

class _RegisterSessionSettingsFields extends StatelessWidget {
  const _RegisterSessionSettingsFields({
    required this.requireOpeningCash,
    required this.enabled,
    required this.returnWindowText,
    required this.onRequireOpeningCashChanged,
    required this.onTap,
  });

  final bool requireOpeningCash;
  final bool enabled;
  final String returnWindowText;
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
      ],
    );
  }
}

class _PaymentSettingsFields extends StatelessWidget {
  const _PaymentSettingsFields({
    required this.cardCommissionController,
    required this.transferCommissionController,
    required this.trustedTerminalIdsController,
    required this.enabled,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.requireCardPaymentReceipt,
    required this.paymentMethodsError,
    required this.cardCommissionError,
    required this.transferCommissionError,
    required this.onEnableCashChanged,
    required this.onEnableCardChanged,
    required this.onRequireCardReceiptChanged,
    required this.onEnableTransferChanged,
    required this.onCommissionChanged,
    required this.onTrustedTerminalIdsChanged,
  });

  final TextEditingController cardCommissionController;
  final TextEditingController transferCommissionController;
  final TextEditingController trustedTerminalIdsController;
  final bool enabled;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardPaymentReceipt;
  final String? paymentMethodsError;
  final String? cardCommissionError;
  final String? transferCommissionError;
  final ValueChanged<bool> onEnableCashChanged;
  final ValueChanged<bool> onEnableCardChanged;
  final ValueChanged<bool> onRequireCardReceiptChanged;
  final ValueChanged<bool> onEnableTransferChanged;
  final VoidCallback onCommissionChanged;
  final VoidCallback onTrustedTerminalIdsChanged;

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
        TextFormField(
          controller: trustedTerminalIdsController,
          enabled: enabled && enableCardPayments,
          minLines: 2,
          maxLines: 4,
          textDirection: TextDirection.ltr,
          onChanged: (_) => onTrustedTerminalIdsChanged(),
          decoration: InputDecoration(
            labelText: l10n.trustedCardTerminalIdsLabel,
            helperText: l10n.trustedCardTerminalIdsHelper,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.point_of_sale_outlined),
          ),
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
            border: const OutlineInputBorder(),
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
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.percent),
          ),
        ),
        if (paymentMethodsError != null) ...[
          const SizedBox(height: 12),
          Text(
            paymentMethodsError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}

class _InventorySettingsFields extends StatelessWidget {
  const _InventorySettingsFields({
    required this.controller,
    required this.enabled,
    required this.errorText,
    required this.allowOverselling,
    required this.preventSellingAtLoss,
    required this.onThresholdChanged,
    required this.onAllowOversellingChanged,
    required this.onPreventSellingAtLossChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final bool allowOverselling;
  final bool preventSellingAtLoss;
  final VoidCallback onThresholdChanged;
  final ValueChanged<bool> onAllowOversellingChanged;
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
            border: const OutlineInputBorder(),
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
          initialValue: format,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportFormatLabel,
            border: const OutlineInputBorder(),
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
          initialValue: eventType,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportEventTypeLabel,
            border: const OutlineInputBorder(),
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
          initialValue: severity,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportSeverityLabel,
            border: const OutlineInputBorder(),
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
          initialValue: source,
          decoration: InputDecoration(
            labelText: l10n.analyticsExportSourceLabel,
            border: const OutlineInputBorder(),
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
            border: const OutlineInputBorder(),
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
            border: const OutlineInputBorder(),
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
            border: const OutlineInputBorder(),
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
            border: const OutlineInputBorder(),
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
          border: const OutlineInputBorder(),
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
          border: const OutlineInputBorder(),
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
    final colorScheme = Theme.of(context).colorScheme;

    return PointyStickyActionFooter(
      summary: hasSaveError
          ? Text(
              l10n.shopSettingsSaveError,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.error),
            )
          : null,
      primaryAction: FilledButton.icon(
        onPressed: isSaving ? null : onSubmit,
        icon: isSaving
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
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
    final colorScheme = Theme.of(context).colorScheme;

    return PointyStickyActionFooter(
      summary: hasExportError
          ? Text(
              l10n.analyticsExportFailedMessage,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.error),
            )
          : null,
      primaryAction: FilledButton.icon(
        key: const ValueKey('analytics_export_download_button'),
        onPressed: isExporting ? null : onSubmit,
        icon: isExporting
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
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
