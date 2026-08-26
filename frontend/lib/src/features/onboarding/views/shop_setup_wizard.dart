import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';

/// First-run wizard shown once, right after the initial admin is created. The
/// owner picks their shop vertical (which flips sensible feature defaults) and
/// confirms a few key settings. Everything stays editable in Settings after.
class ShopSetupWizard extends StatefulWidget {
  const ShopSetupWizard({
    super.key,
    required this.shopSettingsRepository,
    required this.onComplete,
  });

  final ShopSettingsRepository shopSettingsRepository;
  final VoidCallback onComplete;

  @override
  State<ShopSetupWizard> createState() => _ShopSetupWizardState();
}

class _ShopSetupWizardState extends State<ShopSetupWizard> {
  int _step = 0;
  String? _shopType;
  final TextEditingController _shopName = TextEditingController();
  bool _allowOverselling = false;
  bool _requireOpeningCash = true;
  bool _autoPrintReceipts = false;
  InventoryValuationMethod _valuationMethod =
      InventoryValuationMethod.movingAverage;
  bool _isSubmitting = false;
  bool _hasError = false;

  @override
  void dispose() {
    _shopName.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final type = _shopType;
    if (type == null) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _hasError = false;
    });
    final name = _shopName.text.trim();
    final result = await widget.shopSettingsRepository.setupShop(
      shopType: type,
      shopName: name.isEmpty ? null : name,
      allowOverselling: _allowOverselling,
      requireOpeningCash: _requireOpeningCash,
      autoPrintReceipts: _autoPrintReceipts,
      inventoryValuationMethod: _valuationMethod,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<ShopSettings>():
        widget.onComplete();
      case Error<ShopSettings>():
        setState(() {
          _isSubmitting = false;
          _hasError = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return PointyScaffold(
      appBar: PointyAppBar(
        title: Text(l10n.shopSetupTitle),
        reserveLoadingSlot: false,
        actions: [
          TextButton(
            onPressed: _isSubmitting ? null : widget.onComplete,
            child: Text(l10n.shopSetupSkip),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: spacing.pagePadding,
            children: [
              Text(
                _step == 0 ? l10n.shopSetupPickTypeTitle : l10n.shopSetupTuneTitle,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              SizedBox(height: spacing.xs),
              Text(
                _step == 0
                    ? l10n.shopSetupPickTypeSubtitle
                    : l10n.shopSetupTuneSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.pointyColors.mutedInk,
                ),
              ),
              SizedBox(height: spacing.lg),
              if (_step == 0)
                _ShopTypeStep(
                  selected: _shopType,
                  onSelected: (value) => setState(() => _shopType = value),
                )
              else
                _SettingsStep(
                  shopNameController: _shopName,
                  allowOverselling: _allowOverselling,
                  requireOpeningCash: _requireOpeningCash,
                  autoPrintReceipts: _autoPrintReceipts,
                  onAllowOversellingChanged: (v) =>
                      setState(() => _allowOverselling = v),
                  onRequireOpeningCashChanged: (v) =>
                      setState(() => _requireOpeningCash = v),
                  onAutoPrintReceiptsChanged: (v) =>
                      setState(() => _autoPrintReceipts = v),
                  valuationMethod: _valuationMethod,
                  onValuationMethodChanged: (v) =>
                      setState(() => _valuationMethod = v),
                ),
              if (_hasError) ...[
                SizedBox(height: spacing.md),
                PointyInlineMessage.error(message: l10n.shopSetupError),
              ],
              SizedBox(height: spacing.lg),
              Row(
                children: [
                  if (_step == 1)
                    OutlinedButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => setState(() => _step = 0),
                      child: Text(l10n.backButton),
                    ),
                  const Spacer(),
                  if (_step == 0)
                    FilledButton(
                      onPressed: _shopType == null
                          ? null
                          : () => setState(() => _step = 1),
                      child: Text(l10n.nextButton),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _isSubmitting ? null : _finish,
                      icon: _isSubmitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: Text(l10n.shopSetupFinish),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShopTypeStep extends StatelessWidget {
  const _ShopTypeStep({required this.selected, required this.onSelected});

  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final types = _shopTypeOptions(l10n);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 3 : 1;
        final gap = AdaptiveSpacing.of(context).gutter;
        final tileWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final option in types)
              SizedBox(
                width: tileWidth,
                child: _ShopTypeCard(
                  option: option,
                  selected: selected == option.value,
                  onTap: () => onSelected(option.value),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ShopTypeCard extends StatelessWidget {
  const _ShopTypeCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _ShopTypeOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.35)
          : colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PointyRadii.card),
            border: Border.all(
              color: selected ? colors.primaryStrong : colors.line,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(option.icon, color: colors.primaryStrong),
                  const Spacer(),
                  if (selected)
                    Icon(Icons.check_circle, color: colors.primaryStrong),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                option.label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                option.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsStep extends StatelessWidget {
  const _SettingsStep({
    required this.shopNameController,
    required this.allowOverselling,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.onAllowOversellingChanged,
    required this.onRequireOpeningCashChanged,
    required this.onAutoPrintReceiptsChanged,
    required this.valuationMethod,
    required this.onValuationMethodChanged,
  });

  final TextEditingController shopNameController;
  final bool allowOverselling;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final ValueChanged<bool> onAllowOversellingChanged;
  final ValueChanged<bool> onRequireOpeningCashChanged;
  final ValueChanged<bool> onAutoPrintReceiptsChanged;
  final InventoryValuationMethod valuationMethod;
  final ValueChanged<InventoryValuationMethod> onValuationMethodChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: shopNameController,
          decoration: InputDecoration(
            labelText: l10n.shopSetupShopNameLabel,
            prefixIcon: const Icon(Icons.storefront_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: false,
          decoration: InputDecoration(
            labelText: l10n.shopSetupCurrencyLabel,
            helperText: l10n.shopSetupCurrencyHint,
            prefixIcon: const Icon(Icons.payments_outlined),
          ),
          controller: TextEditingController(text: l10n.shopSetupCurrencyValue),
        ),
        const SizedBox(height: 12),
        // Asked here rather than in Settings because it is the one choice on
        // this screen that is genuinely expensive to revisit: it decides what
        // every future sale's cost will be.
        DropdownButtonFormField<InventoryValuationMethod>(
          initialValue: valuationMethod,
          decoration: InputDecoration(
            labelText: l10n.valuationMethodSetupTitle,
            helperText: l10n.valuationMethodSetupSubtitle,
            helperMaxLines: 3,
            prefixIcon: const Icon(Icons.calculate_outlined),
          ),
          items: [
            for (final method in InventoryValuationMethod.values)
              DropdownMenuItem(
                value: method,
                child: Text(_wizardValuationMethodLabel(l10n, method)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              onValuationMethodChanged(value);
            }
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            _wizardValuationMethodDescription(l10n, valuationMethod),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.shopSetupOversellingTitle),
          subtitle: Text(l10n.shopSetupOversellingSubtitle),
          value: allowOverselling,
          onChanged: onAllowOversellingChanged,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.shopSetupOpeningCashTitle),
          subtitle: Text(l10n.shopSetupOpeningCashSubtitle),
          value: requireOpeningCash,
          onChanged: onRequireOpeningCashChanged,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.shopSetupReceiptsTitle),
          subtitle: Text(l10n.shopSetupReceiptsSubtitle),
          value: autoPrintReceipts,
          onChanged: onAutoPrintReceiptsChanged,
        ),
      ],
    );
  }
}

class _ShopTypeOption {
  const _ShopTypeOption({
    required this.value,
    required this.icon,
    required this.label,
    required this.description,
  });

  final String value;
  final IconData icon;
  final String label;
  final String description;
}

List<_ShopTypeOption> _shopTypeOptions(AppLocalizations l10n) {
  return [
    _ShopTypeOption(
      value: 'general',
      icon: Icons.storefront_outlined,
      label: l10n.shopTypeGeneral,
      description: l10n.shopTypeGeneralDescription,
    ),
    _ShopTypeOption(
      value: 'restaurant',
      icon: Icons.restaurant_outlined,
      label: l10n.shopTypeRestaurant,
      description: l10n.shopTypeRestaurantDescription,
    ),
    _ShopTypeOption(
      value: 'grocery',
      icon: Icons.local_grocery_store_outlined,
      label: l10n.shopTypeGrocery,
      description: l10n.shopTypeGroceryDescription,
    ),
    _ShopTypeOption(
      value: 'pharmacy',
      icon: Icons.medical_services_outlined,
      label: l10n.shopTypePharmacy,
      description: l10n.shopTypePharmacyDescription,
    ),
    _ShopTypeOption(
      value: 'phone_repair',
      icon: Icons.smartphone_outlined,
      label: l10n.shopTypePhoneRepair,
      description: l10n.shopTypePhoneRepairDescription,
    ),
    _ShopTypeOption(
      value: 'bakery',
      icon: Icons.bakery_dining_outlined,
      label: l10n.shopTypeBakery,
      description: l10n.shopTypeBakeryDescription,
    ),
    _ShopTypeOption(
      value: 'retail',
      icon: Icons.checkroom_outlined,
      label: l10n.shopTypeRetail,
      description: l10n.shopTypeRetailDescription,
    ),
  ];
}


String _wizardValuationMethodLabel(
  AppLocalizations l10n,
  InventoryValuationMethod method,
) {
  return switch (method) {
    InventoryValuationMethod.movingAverage => l10n.valuationMethodMovingAverage,
    InventoryValuationMethod.fifo => l10n.valuationMethodFifo,
    InventoryValuationMethod.lifo => l10n.valuationMethodLifo,
  };
}

String _wizardValuationMethodDescription(
  AppLocalizations l10n,
  InventoryValuationMethod method,
) {
  return switch (method) {
    InventoryValuationMethod.movingAverage =>
      l10n.valuationMethodMovingAverageDescription,
    InventoryValuationMethod.fifo => l10n.valuationMethodFifoDescription,
    InventoryValuationMethod.lifo => l10n.valuationMethodLifoDescription,
  };
}
