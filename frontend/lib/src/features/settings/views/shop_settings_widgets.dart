part of 'shop_settings_screen.dart';

class _ShopIdentityFields extends StatelessWidget {
  const _ShopIdentityFields({
    required this.controller,
    required this.enabled,
    required this.errorText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return TextFormField(
      controller: controller,
      enabled: enabled,
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        labelText: l10n.shopNameLabel,
        errorText: errorText,
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.storefront_outlined),
      ),
    );
  }
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
    required this.enabled,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.paymentMethodsError,
    required this.cardCommissionError,
    required this.transferCommissionError,
    required this.onEnableCashChanged,
    required this.onEnableCardChanged,
    required this.onEnableTransferChanged,
    required this.onCommissionChanged,
  });

  final TextEditingController cardCommissionController;
  final TextEditingController transferCommissionController;
  final bool enabled;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final String? paymentMethodsError;
  final String? cardCommissionError;
  final String? transferCommissionError;
  final ValueChanged<bool> onEnableCashChanged;
  final ValueChanged<bool> onEnableCardChanged;
  final ValueChanged<bool> onEnableTransferChanged;
  final VoidCallback onCommissionChanged;

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
        const SizedBox(height: 8),
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
    required this.onThresholdChanged,
    required this.onAllowOversellingChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final bool allowOverselling;
  final VoidCallback onThresholdChanged;
  final ValueChanged<bool> onAllowOversellingChanged;

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
      ],
    );
  }
}

class _SettingsListSection extends StatelessWidget {
  const _SettingsListSection({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var index = 0; index < children.length; index++) ...[
            children[index],
            if (index != children.length - 1)
              const Divider(height: 1, indent: 72),
          ],
        ],
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

class _SettingsNavigationTile extends StatelessWidget {
  const _SettingsNavigationTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.hasError = false,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SizedBox.square(
                dimension: 40,
                child: Icon(icon, color: iconColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      color: hasError
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              isRtl ? Icons.chevron_right : Icons.chevron_left,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsDetailSection extends StatelessWidget {
  const _SettingsDetailSection({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
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

    return Material(
      color: colorScheme.surface,
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Row(
              children: [
                if (hasSaveError)
                  Expanded(
                    child: Text(
                      l10n.shopSettingsSaveError,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colorScheme.error),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: isSaving ? null : onSubmit,
                  icon: isSaving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    isSaving
                        ? l10n.savingSettingsButton
                        : l10n.saveSettingsButton,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
