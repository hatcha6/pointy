import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/shop_settings.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../view_models/shop_settings_view_model.dart';

class ShopSettingsScreen extends StatelessWidget {
  const ShopSettingsScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenUsers,
  });

  final ShopSettingsViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenUsers;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.settings,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenPos: onOpenPos,
            onOpenCatalog: onOpenCatalog,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: () {},
            onLogout: onLogout,
          ),
          appBar: AppBar(
            leading: Builder(
              builder: (context) {
                return IconButton(
                  tooltip: l10n.navigationMenuTooltip,
                  icon: const Icon(Icons.menu),
                  onPressed: Scaffold.of(context).openDrawer,
                );
              },
            ),
            title: Text(l10n.shopSettingsTitle),
            actions: [
              ShopSettingsGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshShopSettingsTooltip,
                  onPressed: viewModel.isSaving ? null : viewModel.loadSettings,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: ShopSettingsGuard(
              capabilities: capabilities,
              child: _ShopSettingsBody(viewModel: viewModel),
            ),
          ),
        );
      },
    );
  }
}

class _ShopSettingsBody extends StatelessWidget {
  const _ShopSettingsBody({required this.viewModel});

  final ShopSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoading && viewModel.settings == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (viewModel.hasLoadError && viewModel.settings == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.shopSettingsLoadError, textAlign: TextAlign.center),
        ),
      );
    }

    final settings = viewModel.settings;
    if (settings == null) {
      return const SizedBox.shrink();
    }

    return _ShopSettingsForm(viewModel: viewModel, settings: settings);
  }
}

class _ShopSettingsForm extends StatefulWidget {
  const _ShopSettingsForm({required this.viewModel, required this.settings});

  final ShopSettingsViewModel viewModel;
  final ShopSettings settings;

  @override
  State<_ShopSettingsForm> createState() => _ShopSettingsFormState();
}

class _ShopSettingsFormState extends State<_ShopSettingsForm> {
  late final TextEditingController _shopNameController;
  late final TextEditingController _receiptHeaderController;
  late final TextEditingController _receiptFooterController;
  late final TextEditingController _lowStockThresholdController;
  late bool _requireOpeningCash;
  late bool _autoPrintReceipts;
  bool _showValidationErrors = false;

  @override
  void initState() {
    super.initState();
    _applySettings(widget.settings);
  }

  @override
  void didUpdateWidget(covariant _ShopSettingsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings && !widget.viewModel.isSaving) {
      _setControllerText(_shopNameController, widget.settings.shopName);
      _setControllerText(
        _receiptHeaderController,
        widget.settings.receiptHeader,
      );
      _setControllerText(
        _receiptFooterController,
        widget.settings.receiptFooter,
      );
      _setControllerText(
        _lowStockThresholdController,
        '${widget.settings.lowStockThreshold}',
      );
      _requireOpeningCash = widget.settings.requireOpeningCash;
      _autoPrintReceipts = widget.settings.autoPrintReceipts;
    }
  }

  @override
  void dispose() {
    _shopNameController.dispose();
    _receiptHeaderController.dispose();
    _receiptFooterController.dispose();
    _lowStockThresholdController.dispose();
    super.dispose();
  }

  void _applySettings(ShopSettings settings) {
    _shopNameController = TextEditingController(text: settings.shopName);
    _receiptHeaderController = TextEditingController(
      text: settings.receiptHeader,
    );
    _receiptFooterController = TextEditingController(
      text: settings.receiptFooter,
    );
    _lowStockThresholdController = TextEditingController(
      text: '${settings.lowStockThreshold}',
    );
    _requireOpeningCash = settings.requireOpeningCash;
    _autoPrintReceipts = settings.autoPrintReceipts;
  }

  void _setControllerText(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.text = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SettingsListSection(
                          children: [
                            _SettingsNavigationTile(
                              icon: Icons.storefront_outlined,
                              iconColor: Colors.teal,
                              title: l10n.shopIdentitySectionTitle,
                              subtitle: _shopIdentitySummary(l10n),
                              hasError: _shopNameError(l10n) != null,
                              onTap: widget.viewModel.isSaving
                                  ? null
                                  : () => _openSettingsGroup(
                                      context,
                                      title: l10n.shopIdentitySectionTitle,
                                      icon: Icons.storefront_outlined,
                                      children: _buildIdentityFields,
                                    ),
                            ),
                            _SettingsNavigationTile(
                              icon: Icons.receipt_long_outlined,
                              iconColor: Colors.indigo,
                              title: l10n.receiptSettingsSectionTitle,
                              subtitle: _receiptSummary(l10n),
                              onTap: widget.viewModel.isSaving
                                  ? null
                                  : () => _openSettingsGroup(
                                      context,
                                      title: l10n.receiptSettingsSectionTitle,
                                      icon: Icons.receipt_long_outlined,
                                      children: _buildReceiptFields,
                                    ),
                            ),
                            _SettingsNavigationTile(
                              icon: Icons.point_of_sale_outlined,
                              iconColor: Colors.deepOrange,
                              title: l10n.registerSessionSettingsSectionTitle,
                              subtitle: _registerSessionSummary(l10n),
                              onTap: widget.viewModel.isSaving
                                  ? null
                                  : () => _openSettingsGroup(
                                      context,
                                      title: l10n
                                          .registerSessionSettingsSectionTitle,
                                      icon: Icons.point_of_sale_outlined,
                                      children: _buildRegisterSessionFields,
                                    ),
                            ),
                            _SettingsNavigationTile(
                              icon: Icons.inventory_2_outlined,
                              iconColor: Colors.blueGrey,
                              title: l10n.inventorySettingsSectionTitle,
                              subtitle: _inventorySummary(l10n),
                              hasError: _lowStockThresholdError(l10n) != null,
                              onTap: widget.viewModel.isSaving
                                  ? null
                                  : () => _openSettingsGroup(
                                      context,
                                      title: l10n.inventorySettingsSectionTitle,
                                      icon: Icons.inventory_2_outlined,
                                      children: _buildInventoryFields,
                                    ),
                            ),
                          ],
                        ),
                        if (widget.viewModel.hasSaveError)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              l10n.shopSettingsSaveError,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _SettingsSaveBar(
            isSaving: widget.viewModel.isSaving,
            hasSaveError: widget.viewModel.hasSaveError,
            onSubmit: _submit,
          ),
        ],
      ),
    );
  }

  String _shopIdentitySummary(AppLocalizations l10n) {
    final shopName = _shopNameController.text.trim();
    if (shopName.isEmpty) {
      return l10n.shopSettingsEmptyValue;
    }
    return shopName;
  }

  String _receiptSummary(AppLocalizations l10n) {
    final status = _autoPrintReceipts
        ? l10n.shopSettingsEnabledValue
        : l10n.shopSettingsDisabledValue;
    return l10n.receiptSettingsSummary(status);
  }

  String _registerSessionSummary(AppLocalizations l10n) {
    final status = _requireOpeningCash
        ? l10n.shopSettingsEnabledValue
        : l10n.shopSettingsDisabledValue;
    return l10n.registerSessionSettingsSummary(status);
  }

  String _inventorySummary(AppLocalizations l10n) {
    final count = int.tryParse(_lowStockThresholdController.text.trim()) ?? 0;
    return l10n.inventorySettingsSummary(count);
  }

  String? _shopNameError(AppLocalizations l10n) {
    if (!_showValidationErrors || _shopNameController.text.trim().isNotEmpty) {
      return null;
    }
    return l10n.requiredField;
  }

  String? _lowStockThresholdError(AppLocalizations l10n) {
    final value = _lowStockThresholdController.text.trim();
    if (!_showValidationErrors || value.isNotEmpty) {
      return null;
    }
    return l10n.requiredField;
  }

  List<Widget> _buildIdentityFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      TextFormField(
        controller: _shopNameController,
        enabled: !widget.viewModel.isSaving,
        onChanged: (_) => _refreshSettingsGroup(refresh),
        decoration: InputDecoration(
          labelText: l10n.shopNameLabel,
          errorText: _shopNameError(l10n),
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.storefront_outlined),
        ),
      ),
    ];
  }

  List<Widget> _buildReceiptFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      TextFormField(
        controller: _receiptHeaderController,
        enabled: !widget.viewModel.isSaving,
        maxLines: 2,
        decoration: InputDecoration(
          labelText: l10n.receiptHeaderLabel,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.notes_outlined),
        ),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _receiptFooterController,
        enabled: !widget.viewModel.isSaving,
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
        value: _autoPrintReceipts,
        title: Text(l10n.autoPrintReceiptsLabel),
        onChanged: widget.viewModel.isSaving
            ? null
            : (value) {
                setState(() => _autoPrintReceipts = value);
                refresh();
              },
      ),
    ];
  }

  List<Widget> _buildRegisterSessionFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _requireOpeningCash,
        title: Text(l10n.requireOpeningCashLabel),
        onChanged: widget.viewModel.isSaving
            ? null
            : (value) {
                setState(() => _requireOpeningCash = value);
                refresh();
              },
      ),
    ];
  }

  List<Widget> _buildInventoryFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      TextFormField(
        controller: _lowStockThresholdController,
        enabled: !widget.viewModel.isSaving,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (_) => _refreshSettingsGroup(refresh),
        decoration: InputDecoration(
          labelText: l10n.lowStockThresholdLabel,
          errorText: _lowStockThresholdError(l10n),
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.inventory_outlined),
        ),
      ),
    ];
  }

  void _refreshSettingsGroup(VoidCallback refresh) {
    setState(() {});
    refresh();
  }

  Future<void> _openSettingsGroup(
    BuildContext context, {
    required String title,
    required IconData icon,
    required List<Widget> Function(BuildContext, AppLocalizations, VoidCallback)
    children,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) {
          return StatefulBuilder(
            builder: (context, setRouteState) {
              void refreshRoute() => setRouteState(() {});

              return ListenableBuilder(
                listenable: widget.viewModel,
                builder: (context, _) {
                  final l10n = AppLocalizations.of(context)!;

                  return Scaffold(
                    appBar: AppBar(title: Text(title)),
                    body: SafeArea(
                      child: ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLowest,
                        child: Column(
                          children: [
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  20,
                                ),
                                children: [
                                  Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 720,
                                      ),
                                      child: _SettingsDetailSection(
                                        icon: icon,
                                        title: title,
                                        children: children(
                                          context,
                                          l10n,
                                          refreshRoute,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _SettingsSaveBar(
                              isSaving: widget.viewModel.isSaving,
                              hasSaveError: widget.viewModel.hasSaveError,
                              onSubmit: () {
                                _submit();
                                refreshRoute();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _showValidationErrors = true);

    if (_shopNameError(l10n) != null || _lowStockThresholdError(l10n) != null) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final saved = await widget.viewModel.updateSettings(
      ShopSettingsDraft(
        shopName: _shopNameController.text.trim(),
        receiptHeader: _receiptHeaderController.text.trim(),
        receiptFooter: _receiptFooterController.text.trim(),
        requireOpeningCash: _requireOpeningCash,
        autoPrintReceipts: _autoPrintReceipts,
        lowStockThreshold:
            int.tryParse(_lowStockThresholdController.text.trim()) ?? 0,
      ),
    );

    if (!mounted) {
      return;
    }

    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            saved ? l10n.shopSettingsSavedMessage : l10n.shopSettingsSaveError,
          ),
        ),
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
