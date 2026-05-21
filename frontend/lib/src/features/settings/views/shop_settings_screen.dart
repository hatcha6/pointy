import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/shop_settings.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../view_models/shop_settings_view_model.dart';

part 'shop_settings_widgets.dart';

class ShopSettingsScreen extends StatelessWidget {
  const ShopSettingsScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenUsers,
  });

  final ShopSettingsViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
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
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
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
  late final TextEditingController _cardCommissionController;
  late final TextEditingController _transferCommissionController;
  late int _cashierReturnWindowHours;
  late bool _requireOpeningCash;
  late bool _autoPrintReceipts;
  late bool _allowOverselling;
  late bool _enableCashPayments;
  late bool _enableCardPayments;
  late bool _enableTransferPayments;
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
      _setControllerText(
        _cardCommissionController,
        widget.settings.cardCommissionPercent.toStringAsFixed(2),
      );
      _setControllerText(
        _transferCommissionController,
        widget.settings.transferCommissionPercent.toStringAsFixed(2),
      );
      _cashierReturnWindowHours = widget.settings.cashierReturnWindowHours;
      _requireOpeningCash = widget.settings.requireOpeningCash;
      _autoPrintReceipts = widget.settings.autoPrintReceipts;
      _allowOverselling = widget.settings.allowOverselling;
      _enableCashPayments = widget.settings.enableCashPayments;
      _enableCardPayments = widget.settings.enableCardPayments;
      _enableTransferPayments = widget.settings.enableTransferPayments;
    }
  }

  @override
  void dispose() {
    _shopNameController.dispose();
    _receiptHeaderController.dispose();
    _receiptFooterController.dispose();
    _lowStockThresholdController.dispose();
    _cardCommissionController.dispose();
    _transferCommissionController.dispose();
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
    _cardCommissionController = TextEditingController(
      text: settings.cardCommissionPercent.toStringAsFixed(2),
    );
    _transferCommissionController = TextEditingController(
      text: settings.transferCommissionPercent.toStringAsFixed(2),
    );
    _cashierReturnWindowHours = settings.cashierReturnWindowHours;
    _requireOpeningCash = settings.requireOpeningCash;
    _autoPrintReceipts = settings.autoPrintReceipts;
    _allowOverselling = settings.allowOverselling;
    _enableCashPayments = settings.enableCashPayments;
    _enableCardPayments = settings.enableCardPayments;
    _enableTransferPayments = settings.enableTransferPayments;
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
                              icon: Icons.payments_outlined,
                              iconColor: Colors.green,
                              title: l10n.paymentSettingsSectionTitle,
                              subtitle: _paymentSummary(l10n),
                              hasError:
                                  _paymentMethodsError(l10n) != null ||
                                  _commissionError(
                                        l10n,
                                        _cardCommissionController,
                                      ) !=
                                      null ||
                                  _commissionError(
                                        l10n,
                                        _transferCommissionController,
                                      ) !=
                                      null,
                              onTap: widget.viewModel.isSaving
                                  ? null
                                  : () => _openSettingsGroup(
                                      context,
                                      title: l10n.paymentSettingsSectionTitle,
                                      icon: Icons.payments_outlined,
                                      children: _buildPaymentFields,
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
    return l10n.registerSessionSettingsSummary(
      status,
      _formatCashierReturnWindow(l10n),
    );
  }

  String _inventorySummary(AppLocalizations l10n) {
    final count = int.tryParse(_lowStockThresholdController.text.trim()) ?? 0;
    final status = _allowOverselling
        ? l10n.shopSettingsEnabledValue
        : l10n.shopSettingsDisabledValue;
    return l10n.inventorySettingsSummary(count, status);
  }

  String _paymentSummary(AppLocalizations l10n) {
    final enabledCount = [
      _enableCashPayments,
      _enableCardPayments,
      _enableTransferPayments,
    ].where((enabled) => enabled).length;
    return l10n.paymentSettingsSummary(
      enabledCount,
      _cardCommissionController.text.trim(),
      _transferCommissionController.text.trim(),
    );
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

  String? _paymentMethodsError(AppLocalizations l10n) {
    if (!_showValidationErrors ||
        _enableCashPayments ||
        _enableCardPayments ||
        _enableTransferPayments) {
      return null;
    }
    return l10n.paymentMethodsRequiredError;
  }

  String? _commissionError(
    AppLocalizations l10n,
    TextEditingController controller,
  ) {
    final value = controller.text.trim().replaceAll(',', '.');
    if (!_showValidationErrors || double.tryParse(value) != null) {
      return null;
    }
    return l10n.invalidNumber;
  }

  List<Widget> _buildIdentityFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      _ShopIdentityFields(
        controller: _shopNameController,
        enabled: !widget.viewModel.isSaving,
        errorText: _shopNameError(l10n),
        onChanged: () => _refreshSettingsGroup(refresh),
      ),
    ];
  }

  List<Widget> _buildReceiptFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      _ReceiptSettingsFields(
        headerController: _receiptHeaderController,
        footerController: _receiptFooterController,
        autoPrintReceipts: _autoPrintReceipts,
        enabled: !widget.viewModel.isSaving,
        onAutoPrintReceiptsChanged: (value) {
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
      _RegisterSessionSettingsFields(
        requireOpeningCash: _requireOpeningCash,
        enabled: !widget.viewModel.isSaving,
        returnWindowText: _formatCashierReturnWindow(l10n),
        onRequireOpeningCashChanged: (value) {
          setState(() => _requireOpeningCash = value);
          refresh();
        },
        onTap: () => _pickCashierReturnWindow(context, l10n, refresh),
      ),
    ];
  }

  List<Widget> _buildPaymentFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      _PaymentSettingsFields(
        cardCommissionController: _cardCommissionController,
        transferCommissionController: _transferCommissionController,
        enabled: !widget.viewModel.isSaving,
        enableCashPayments: _enableCashPayments,
        enableCardPayments: _enableCardPayments,
        enableTransferPayments: _enableTransferPayments,
        paymentMethodsError: _paymentMethodsError(l10n),
        cardCommissionError: _commissionError(l10n, _cardCommissionController),
        transferCommissionError: _commissionError(
          l10n,
          _transferCommissionController,
        ),
        onEnableCashChanged: (value) {
          setState(() => _enableCashPayments = value);
          refresh();
        },
        onEnableCardChanged: (value) {
          setState(() => _enableCardPayments = value);
          refresh();
        },
        onEnableTransferChanged: (value) {
          setState(() => _enableTransferPayments = value);
          refresh();
        },
        onCommissionChanged: () => _refreshSettingsGroup(refresh),
      ),
    ];
  }

  List<Widget> _buildInventoryFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      _InventorySettingsFields(
        controller: _lowStockThresholdController,
        enabled: !widget.viewModel.isSaving,
        errorText: _lowStockThresholdError(l10n),
        allowOverselling: _allowOverselling,
        onThresholdChanged: () => _refreshSettingsGroup(refresh),
        onAllowOversellingChanged: (value) {
          setState(() => _allowOverselling = value);
          refresh();
        },
      ),
    ];
  }

  String _formatCashierReturnWindow(AppLocalizations l10n) {
    final days = _cashierReturnWindowHours ~/ 24;
    final hours = _cashierReturnWindowHours % 24;
    if (days == 0) {
      return l10n.cashierReturnWindowHoursValue(hours);
    }
    if (hours == 0) {
      return l10n.cashierReturnWindowDaysValue(days);
    }
    return l10n.cashierReturnWindowDaysHoursValue(days, hours);
  }

  Future<void> _pickCashierReturnWindow(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (context) {
        var selectedDays = _cashierReturnWindowHours ~/ 24;
        var selectedHours = _cashierReturnWindowHours % 24;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              icon: const Icon(Icons.schedule_outlined),
              title: Text(l10n.cashierReturnWindowDialogTitle),
              content: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: selectedDays,
                      decoration: InputDecoration(
                        labelText: l10n.cashierReturnWindowDaysLabel,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (var value = 0; value <= 30; value++)
                          DropdownMenuItem<int>(
                            value: value,
                            child: Text('$value'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setDialogState(() => selectedDays = value);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: selectedHours,
                      decoration: InputDecoration(
                        labelText: l10n.cashierReturnWindowHoursLabel,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (var value = 0; value < 24; value++)
                          DropdownMenuItem<int>(
                            value: value,
                            child: Text('$value'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setDialogState(() => selectedHours = value);
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelButton),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(
                      context,
                    ).pop(selectedDays * 24 + selectedHours);
                  },
                  child: Text(l10n.confirmButton),
                ),
              ],
            );
          },
        );
      },
    );
    if (picked == null) {
      return;
    }

    setState(() => _cashierReturnWindowHours = picked);
    refresh();
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

    if (_shopNameError(l10n) != null ||
        _lowStockThresholdError(l10n) != null ||
        _paymentMethodsError(l10n) != null ||
        _commissionError(l10n, _cardCommissionController) != null ||
        _commissionError(l10n, _transferCommissionController) != null) {
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
        allowOverselling: _allowOverselling,
        lowStockThreshold:
            int.tryParse(_lowStockThresholdController.text.trim()) ?? 0,
        cashierReturnWindowHours: _cashierReturnWindowHours,
        enableCashPayments: _enableCashPayments,
        enableCardPayments: _enableCardPayments,
        enableTransferPayments: _enableTransferPayments,
        cardCommissionPercent: _parsePercent(_cardCommissionController.text),
        transferCommissionPercent: _parsePercent(
          _transferCommissionController.text,
        ),
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

  double _parsePercent(String value) {
    return double.parse(value.trim().replaceAll(',', '.'));
  }
}
