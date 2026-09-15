import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/parsing.dart';
import '../../../data/models/analytics_export.dart';
import '../../../data/models/attachment_summary.dart';
import '../../../data/models/contact.dart' show PaymentTermsBasis;
import '../../../data/models/shop_settings.dart';
import '../../../data/models/system_backup.dart';
import '../../../data/services/analytics_export_downloader.dart';
import '../../../data/services/client_update_service.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../attendance/view_models/attendance_view_model.dart';
import '../../attendance/views/attendance_settings_page.dart';
import '../../migration/view_models/migration_view_model.dart';
import '../../migration/views/data_migration_page.dart';
import '../../operations/view_models/asset_types_view_model.dart';
import '../../operations/view_models/workflows_view_model.dart';
import '../view_models/modifier_groups_view_model.dart';
import '../view_models/prep_stations_view_model.dart';
import '../view_models/price_checkers_view_model.dart';
import '../view_models/sales_channels_view_model.dart';
import '../view_models/warehouses_view_model.dart';
import '../../scales/view_models/scales_view_model.dart';
import '../../scales/views/scales_screen.dart';
import '../view_models/shop_settings_view_model.dart';
import '../view_models/messaging_settings_view_model.dart';
import '../view_models/exchange_rates_view_model.dart';
import '../view_models/subscription_status_view_model.dart';
import 'operations_settings_page.dart';
import 'app_updates_page.dart';
import '../../cameras/view_models/camera_settings_view_model.dart';
import '../../cameras/views/camera_settings_page.dart';
import 'price_checkers_page.dart';
import 'sales_channels_page.dart';
import '../../inventory/views/transfers_screen.dart';
import '../../inventory/view_models/transfers_view_model.dart';
import '../../../data/repositories/warehouse_repository.dart';
import 'warehouses_page.dart';
import 'messaging_settings_page.dart';
import 'exchange_rates_page.dart';
import 'analytics_purge_section.dart';
import 'subscription_status_page.dart';
import '../../../shared/formatters.dart';

part 'shop_settings_widgets.dart';
part 'shop_backup_widgets.dart';

class ShopSettingsScreen extends StatelessWidget {
  const ShopSettingsScreen({
    super.key,
    required this.viewModel,
    required this.salesChannelsViewModel,
    required this.warehousesViewModel,
    required this.transfersViewModel,
    required this.warehouseRepository,
    required this.priceCheckersViewModel,
    required this.cameraSettingsViewModel,
    required this.scalesViewModel,
    required this.workflowsViewModel,
    required this.assetTypesViewModel,
    required this.prepStationsViewModel,
    required this.modifierGroupsViewModel,
    required this.attendanceViewModel,
    required this.migrationViewModel,
    required this.subscriptionViewModel,
    required this.exchangeRatesViewModel,
    required this.messagingViewModel,
    required this.clientUpdateService,
    required this.capabilities,
    required this.navigation,
  });

  final ShopSettingsViewModel viewModel;
  final SalesChannelsViewModel salesChannelsViewModel;
  final WarehousesViewModel warehousesViewModel;
  final TransfersViewModel transfersViewModel;
  final WarehouseRepository warehouseRepository;
  final PriceCheckersViewModel priceCheckersViewModel;
  final CameraSettingsViewModel cameraSettingsViewModel;
  final ScalesViewModel scalesViewModel;
  final WorkflowsViewModel workflowsViewModel;
  final AssetTypesViewModel assetTypesViewModel;
  final PrepStationsViewModel prepStationsViewModel;
  final ModifierGroupsViewModel modifierGroupsViewModel;
  final AttendanceViewModel attendanceViewModel;
  final MigrationViewModel migrationViewModel;
  final SubscriptionStatusViewModel subscriptionViewModel;
  final ExchangeRatesViewModel exchangeRatesViewModel;
  final MessagingSettingsViewModel messagingViewModel;
  final ClientUpdateService clientUpdateService;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.settings,
            navigation: navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.shopSettingsTitle),
            isLoading: viewModel.isLoading || viewModel.isSaving,
            reserveLoadingSlot: false,
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
          body: ShopSettingsGuard(
            capabilities: capabilities,
            child: _ShopSettingsBody(
              viewModel: viewModel,
              salesChannelsViewModel: salesChannelsViewModel,
              warehousesViewModel: warehousesViewModel,
              transfersViewModel: transfersViewModel,
              warehouseRepository: warehouseRepository,
              priceCheckersViewModel: priceCheckersViewModel,
              cameraSettingsViewModel: cameraSettingsViewModel,
              scalesViewModel: scalesViewModel,
              workflowsViewModel: workflowsViewModel,
              assetTypesViewModel: assetTypesViewModel,
              prepStationsViewModel: prepStationsViewModel,
              modifierGroupsViewModel: modifierGroupsViewModel,
              attendanceViewModel: attendanceViewModel,
              migrationViewModel: migrationViewModel,
              subscriptionViewModel: subscriptionViewModel,
              exchangeRatesViewModel: exchangeRatesViewModel,
              messagingViewModel: messagingViewModel,
              clientUpdateService: clientUpdateService,
              canManageSalesChannels: capabilities.canManageSalesChannels,
              canManagePriceCheckers: capabilities.canManagePriceCheckers,
              canManageCameras: capabilities.canManageCameras,
              canManageScales: capabilities.canManageScales,
              canManageWorkflows: capabilities.canManageWorkflows,
              canManageAttendance: capabilities.canManageAttendance,
              canManageMessaging: capabilities.canManageMessaging,
            ),
          ),
        );
      },
    );
  }
}

class _ShopSettingsBody extends StatelessWidget {
  const _ShopSettingsBody({
    required this.viewModel,
    required this.salesChannelsViewModel,
    required this.warehousesViewModel,
    required this.transfersViewModel,
    required this.warehouseRepository,
    required this.priceCheckersViewModel,
    required this.cameraSettingsViewModel,
    required this.scalesViewModel,
    required this.workflowsViewModel,
    required this.assetTypesViewModel,
    required this.prepStationsViewModel,
    required this.modifierGroupsViewModel,
    required this.attendanceViewModel,
    required this.migrationViewModel,
    required this.subscriptionViewModel,
    required this.exchangeRatesViewModel,
    required this.messagingViewModel,
    required this.clientUpdateService,
    required this.canManageSalesChannels,
    required this.canManagePriceCheckers,
    required this.canManageCameras,
    required this.canManageScales,
    required this.canManageWorkflows,
    required this.canManageAttendance,
    required this.canManageMessaging,
  });

  final ShopSettingsViewModel viewModel;
  final SalesChannelsViewModel salesChannelsViewModel;
  final WarehousesViewModel warehousesViewModel;
  final TransfersViewModel transfersViewModel;
  final WarehouseRepository warehouseRepository;
  final PriceCheckersViewModel priceCheckersViewModel;
  final CameraSettingsViewModel cameraSettingsViewModel;
  final ScalesViewModel scalesViewModel;
  final WorkflowsViewModel workflowsViewModel;
  final AssetTypesViewModel assetTypesViewModel;
  final PrepStationsViewModel prepStationsViewModel;
  final ModifierGroupsViewModel modifierGroupsViewModel;
  final AttendanceViewModel attendanceViewModel;
  final MigrationViewModel migrationViewModel;
  final SubscriptionStatusViewModel subscriptionViewModel;
  final ExchangeRatesViewModel exchangeRatesViewModel;
  final MessagingSettingsViewModel messagingViewModel;
  final ClientUpdateService clientUpdateService;
  final bool canManageSalesChannels;
  final bool canManagePriceCheckers;
  final bool canManageCameras;
  final bool canManageScales;
  final bool canManageWorkflows;
  final bool canManageAttendance;
  final bool canManageMessaging;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoading && viewModel.settings == null) {
      return const PointyLoadingArea();
    }

    if (viewModel.hasLoadError && viewModel.settings == null) {
      return PointyErrorState(
        title: l10n.shopSettingsLoadError,
        icon: Icons.settings_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadSettings,
          icon: const Icon(Icons.sync),
          label: Text(l10n.refreshShopSettingsTooltip),
        ),
      );
    }

    final settings = viewModel.settings;
    if (settings == null) {
      return const SizedBox.shrink();
    }

    return _ShopSettingsForm(
      viewModel: viewModel,
      salesChannelsViewModel: salesChannelsViewModel,
      warehousesViewModel: warehousesViewModel,
      transfersViewModel: transfersViewModel,
      warehouseRepository: warehouseRepository,
      priceCheckersViewModel: priceCheckersViewModel,
      cameraSettingsViewModel: cameraSettingsViewModel,
      scalesViewModel: scalesViewModel,
      workflowsViewModel: workflowsViewModel,
      assetTypesViewModel: assetTypesViewModel,
      prepStationsViewModel: prepStationsViewModel,
      modifierGroupsViewModel: modifierGroupsViewModel,
      attendanceViewModel: attendanceViewModel,
      migrationViewModel: migrationViewModel,
      subscriptionViewModel: subscriptionViewModel,
      exchangeRatesViewModel: exchangeRatesViewModel,
      messagingViewModel: messagingViewModel,
      clientUpdateService: clientUpdateService,
      canManageSalesChannels: canManageSalesChannels,
      canManagePriceCheckers: canManagePriceCheckers,
      canManageCameras: canManageCameras,
      canManageScales: canManageScales,
      canManageWorkflows: canManageWorkflows,
      canManageAttendance: canManageAttendance,
      canManageMessaging: canManageMessaging,
      settings: settings,
    );
  }
}

class _ShopSettingsForm extends StatefulWidget {
  const _ShopSettingsForm({
    required this.viewModel,
    required this.salesChannelsViewModel,
    required this.warehousesViewModel,
    required this.transfersViewModel,
    required this.warehouseRepository,
    required this.priceCheckersViewModel,
    required this.cameraSettingsViewModel,
    required this.scalesViewModel,
    required this.workflowsViewModel,
    required this.assetTypesViewModel,
    required this.prepStationsViewModel,
    required this.modifierGroupsViewModel,
    required this.attendanceViewModel,
    required this.migrationViewModel,
    required this.subscriptionViewModel,
    required this.exchangeRatesViewModel,
    required this.messagingViewModel,
    required this.clientUpdateService,
    required this.canManageSalesChannels,
    required this.canManagePriceCheckers,
    required this.canManageCameras,
    required this.canManageScales,
    required this.canManageWorkflows,
    required this.canManageAttendance,
    required this.canManageMessaging,
    required this.settings,
  });

  final ShopSettingsViewModel viewModel;
  final SalesChannelsViewModel salesChannelsViewModel;
  final WarehousesViewModel warehousesViewModel;
  final TransfersViewModel transfersViewModel;
  final WarehouseRepository warehouseRepository;
  final PriceCheckersViewModel priceCheckersViewModel;
  final CameraSettingsViewModel cameraSettingsViewModel;
  final ScalesViewModel scalesViewModel;
  final WorkflowsViewModel workflowsViewModel;
  final AssetTypesViewModel assetTypesViewModel;
  final PrepStationsViewModel prepStationsViewModel;
  final ModifierGroupsViewModel modifierGroupsViewModel;
  final AttendanceViewModel attendanceViewModel;
  final MigrationViewModel migrationViewModel;
  final SubscriptionStatusViewModel subscriptionViewModel;
  final ExchangeRatesViewModel exchangeRatesViewModel;
  final MessagingSettingsViewModel messagingViewModel;
  final ClientUpdateService clientUpdateService;
  final bool canManageSalesChannels;
  final bool canManagePriceCheckers;
  final bool canManageCameras;
  final bool canManageScales;
  final bool canManageWorkflows;
  final bool canManageAttendance;
  final bool canManageMessaging;
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
  late final TextEditingController _autoPrintMinLineCountController;
  late final TextEditingController _autoPrintMinTotalController;
  late final TextEditingController _posCashPurchaseLimitController;
  late final TextEditingController _defaultCustomerCreditLimitController;
  late final TextEditingController _defaultPaymentTermsDaysController;
  late PaymentTermsBasis _defaultPaymentTermsBasis;
  late final TextEditingController _analyticsSearchController;
  late final TextEditingController _analyticsPlatformController;
  late final TextEditingController _analyticsSessionController;
  late final TextEditingController _analyticsDeviceController;
  late int _cashierReturnWindowHours;
  late bool _requireOpeningCash;
  late bool _autoPrintReceipts;
  late bool _enableOnlineInvoices;
  late bool _allowOverselling;
  late bool _warnLowStockBeforeSale;
  late bool _preventSellingAtLoss;
  late bool _enablePurchaseSuggestions;
  late InventoryValuationMethod _inventoryValuationMethod;
  late bool _enableCashPayments;
  late bool _enableCardPayments;
  late bool _enableTransferPayments;
  late bool _requireCardPaymentReceipt;
  late bool _requireCustomerForCredit;
  late bool _enforceCustomerCreditLimits;
  late bool _allowCashierCustomerAccess;
  late List<String> _trustedCardTerminalIds;
  AttachmentSummary? _logoAttachment;
  ShopLogoUpload? _selectedLogoUpload;
  bool _removeLogo = false;
  AnalyticsExportFormat _analyticsExportFormat = AnalyticsExportFormat.csv;
  DateTime? _analyticsOccurredFrom;
  DateTime? _analyticsOccurredTo;
  String _analyticsEventType = '';
  String _analyticsSeverity = '';
  String _analyticsSource = '';
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
      _setControllerText(
        _autoPrintMinLineCountController,
        _formatAutoPrintFloorLines(widget.settings.autoPrintMinLineCount),
      );
      _setControllerText(
        _autoPrintMinTotalController,
        _formatAutoPrintFloorTotal(widget.settings.autoPrintMinTotal),
      );
      _setControllerText(
        _posCashPurchaseLimitController,
        _formatPosCashPurchaseLimit(widget.settings.posCashPurchaseLimit),
      );
      _setControllerText(
        _defaultCustomerCreditLimitController,
        _formatCreditLimit(widget.settings.defaultCustomerCreditLimit),
      );
      _setControllerText(
        _defaultPaymentTermsDaysController,
        widget.settings.defaultPaymentTermsDays.toString(),
      );
      _defaultPaymentTermsBasis = widget.settings.defaultPaymentTermsBasis;
      _cashierReturnWindowHours = widget.settings.cashierReturnWindowHours;
      _requireOpeningCash = widget.settings.requireOpeningCash;
      _autoPrintReceipts = widget.settings.autoPrintReceipts;
      _enableOnlineInvoices = widget.settings.enableOnlineInvoices;
      _allowOverselling = widget.settings.allowOverselling;
      _warnLowStockBeforeSale = widget.settings.warnLowStockBeforeSale;
      _preventSellingAtLoss = widget.settings.preventSellingAtLoss;
      _enablePurchaseSuggestions = widget.settings.enablePurchaseSuggestions;
      _inventoryValuationMethod = widget.settings.inventoryValuationMethod;
      _enableCashPayments = widget.settings.enableCashPayments;
      _enableCardPayments = widget.settings.enableCardPayments;
      _enableTransferPayments = widget.settings.enableTransferPayments;
      _requireCardPaymentReceipt = widget.settings.requireCardPaymentReceipt;
      _requireCustomerForCredit = widget.settings.requireCustomerForCredit;
      _enforceCustomerCreditLimits =
          widget.settings.enforceCustomerCreditLimits;
      _allowCashierCustomerAccess = widget.settings.allowCashierCustomerAccess;
      _trustedCardTerminalIds = _normalizeTrustedTerminalIds(
        widget.settings.trustedCardTerminalIds,
      );
      _logoAttachment = widget.settings.logoAttachment;
      _selectedLogoUpload = null;
      _removeLogo = false;
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
    _autoPrintMinLineCountController.dispose();
    _autoPrintMinTotalController.dispose();
    _posCashPurchaseLimitController.dispose();
    _defaultCustomerCreditLimitController.dispose();
    _defaultPaymentTermsDaysController.dispose();
    _analyticsSearchController.dispose();
    _analyticsPlatformController.dispose();
    _analyticsSessionController.dispose();
    _analyticsDeviceController.dispose();
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
    _autoPrintMinLineCountController = TextEditingController(
      text: _formatAutoPrintFloorLines(settings.autoPrintMinLineCount),
    );
    _autoPrintMinTotalController = TextEditingController(
      text: _formatAutoPrintFloorTotal(settings.autoPrintMinTotal),
    );
    _posCashPurchaseLimitController = TextEditingController(
      text: _formatPosCashPurchaseLimit(settings.posCashPurchaseLimit),
    );
    _defaultCustomerCreditLimitController = TextEditingController(
      text: _formatCreditLimit(settings.defaultCustomerCreditLimit),
    );
    _defaultPaymentTermsDaysController = TextEditingController(
      text: settings.defaultPaymentTermsDays.toString(),
    );
    _defaultPaymentTermsBasis = settings.defaultPaymentTermsBasis;
    _analyticsSearchController = TextEditingController();
    _analyticsPlatformController = TextEditingController();
    _analyticsSessionController = TextEditingController();
    _analyticsDeviceController = TextEditingController();
    _cashierReturnWindowHours = settings.cashierReturnWindowHours;
    _requireOpeningCash = settings.requireOpeningCash;
    _autoPrintReceipts = settings.autoPrintReceipts;
    _enableOnlineInvoices = settings.enableOnlineInvoices;
    _allowOverselling = settings.allowOverselling;
    _warnLowStockBeforeSale = settings.warnLowStockBeforeSale;
    _preventSellingAtLoss = settings.preventSellingAtLoss;
    _enablePurchaseSuggestions = settings.enablePurchaseSuggestions;
    _inventoryValuationMethod = settings.inventoryValuationMethod;
    _enableCashPayments = settings.enableCashPayments;
    _enableCardPayments = settings.enableCardPayments;
    _enableTransferPayments = settings.enableTransferPayments;
    _requireCardPaymentReceipt = settings.requireCardPaymentReceipt;
    _requireCustomerForCredit = settings.requireCustomerForCredit;
    _enforceCustomerCreditLimits = settings.enforceCustomerCreditLimits;
    _allowCashierCustomerAccess = settings.allowCashierCustomerAccess;
    _trustedCardTerminalIds = _normalizeTrustedTerminalIds(
      settings.trustedCardTerminalIds,
    );
    _logoAttachment = settings.logoAttachment;
    _selectedLogoUpload = null;
    _removeLogo = false;
  }

  /// Blank = no floor, on both halves. A 0 is stored as "no floor" too (see
  /// [ShopSettings.saleClearsAutoPrintFloor]), so it renders as an empty box
  /// rather than a 0 the owner would read as a rule.
  static String _formatAutoPrintFloorLines(int? lines) {
    if (lines == null || lines <= 0) {
      return '';
    }
    return '$lines';
  }

  static String _formatAutoPrintFloorTotal(double? total) {
    if (total == null || total <= 0) {
      return '';
    }
    return total == total.roundToDouble()
        ? total.toStringAsFixed(0)
        : total.toStringAsFixed(2);
  }

  int? _parseAutoPrintMinLineCount() {
    final parsed = int.tryParse(_autoPrintMinLineCountController.text.trim());
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return parsed;
  }

  double? _parseAutoPrintMinTotal() {
    final parsed = double.tryParse(_autoPrintMinTotalController.text.trim());
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return parsed;
  }

  static String _formatPosCashPurchaseLimit(double? limit) {
    if (limit == null || limit <= 0) {
      return '';
    }
    return limit == limit.roundToDouble()
        ? limit.toStringAsFixed(0)
        : limit.toStringAsFixed(2);
  }

  static String _formatCreditLimit(double? limit) {
    if (limit == null) {
      return '';
    }
    return limit == limit.roundToDouble()
        ? limit.toStringAsFixed(0)
        : limit.toStringAsFixed(2);
  }

  /// Blank = no limit. 0 is kept, because "nobody buys on credit by default" is
  /// a thing an owner means to say — this is the one place it differs from the
  /// cash-purchase cap below, where 0 would simply disable the feature.
  double? _parseDefaultCustomerCreditLimit() {
    final text = _defaultCustomerCreditLimitController.text.trim();
    if (text.isEmpty) {
      return null;
    }
    final parsed = double.tryParse(text);
    if (parsed == null || parsed < 0) {
      return null;
    }
    return parsed;
  }

  double? _parsePosCashPurchaseLimit() {
    final parsed = double.tryParse(_posCashPurchaseLimitController.text.trim());
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return parsed;
  }

  void _setControllerText(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.text = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: spacing.pagePadding,
            children: [
              AdaptiveMaxWidth(
                width: AppContentWidth.form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PointySettingsSection(
                      children: [
                        PointySettingsTile(
                          icon: Icons.system_update_outlined,
                          title: l10n.clientUpdatesTitle,
                          subtitle: l10n.clientUpdatesSubtitle,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => AppUpdatesPage(
                                service: widget.clientUpdateService,
                              ),
                            ),
                          ),
                        ),
                        PointySettingsTile(
                          icon: Icons.qr_code_2_outlined,
                          title: l10n.getAppsTitle,
                          subtitle: l10n.getAppsSubtitle,
                          onTap: () async {
                            final downloadUrl = await widget.clientUpdateService
                                .lanDownloadUrl();
                            if (!context.mounted) return;
                            await showGetAppsDialog(
                              context,
                              downloadUrl: downloadUrl,
                            );
                          },
                        ),
                        PointySettingsTile(
                          icon: Icons.storefront_outlined,
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
                        PointySettingsTile(
                          icon: Icons.receipt_long_outlined,
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
                        PointySettingsTile(
                          icon: Icons.point_of_sale_outlined,
                          title: l10n.registerSessionSettingsSectionTitle,
                          subtitle: _registerSessionSummary(l10n),
                          onTap: widget.viewModel.isSaving
                              ? null
                              : () => _openSettingsGroup(
                                  context,
                                  title:
                                      l10n.registerSessionSettingsSectionTitle,
                                  icon: Icons.point_of_sale_outlined,
                                  children: _buildRegisterSessionFields,
                                ),
                        ),
                        PointySettingsTile(
                          icon: Icons.payments_outlined,
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
                        PointySettingsTile(
                          icon: Icons.inventory_2_outlined,
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
                        if (widget.canManageWorkflows)
                          PointySettingsTile(
                            icon: Icons.handyman_outlined,
                            title: l10n.operationsSettingsSectionTitle,
                            subtitle: l10n.operationsSettingsSectionSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openOperationsSettings(context),
                          ),
                        if (widget.canManageSalesChannels)
                          PointySettingsTile(
                            icon: Icons.hub_outlined,
                            title: l10n.salesChannelsSectionTitle,
                            subtitle: l10n.salesChannelsSectionSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openSalesChannels(context),
                          ),
                        if (widget.canManageSalesChannels)
                          PointySettingsTile(
                            icon: Icons.warehouse_outlined,
                            title: l10n.warehousesSectionTitle,
                            subtitle: l10n.warehousesSectionSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openWarehouses(context),
                          ),
                        if (widget.canManageSalesChannels)
                          PointySettingsTile(
                            icon: Icons.swap_horiz,
                            title: l10n.transfersSectionTitle,
                            subtitle: l10n.transfersSectionSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openTransfers(context),
                          ),
                        if (widget.canManagePriceCheckers)
                          PointySettingsTile(
                            icon: Icons.price_check_outlined,
                            title: l10n.priceCheckersSectionTitle,
                            subtitle: l10n.priceCheckersSectionSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openPriceCheckers(context),
                          ),
                        if (widget.canManageCameras)
                          PointySettingsTile(
                            icon: Icons.videocam_outlined,
                            title: l10n.cameraSettingsTitle,
                            subtitle: l10n.cameraSettingsSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openCameraSettings(context),
                          ),
                        if (widget.canManageScales)
                          PointySettingsTile(
                            icon: Icons.scale_outlined,
                            title: l10n.scalesTitle,
                            subtitle: l10n.scalesIntroMessage,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openScales(context),
                          ),
                        if (widget.canManageAttendance)
                          PointySettingsTile(
                            icon: Icons.fingerprint,
                            title: l10n.attendanceSettingsSectionTitle,
                            subtitle: l10n.attendanceSettingsSectionSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openAttendanceSettings(context),
                          ),
                        if (widget.canManageMessaging)
                          PointySettingsTile(
                            icon: Icons.sms_outlined,
                            title: l10n.messagingSettingsTitle,
                            subtitle: l10n.messagingSettingsSubtitle,
                            onTap: widget.viewModel.isSaving
                                ? null
                                : () => _openMessagingSettings(context),
                          ),
                        PointySettingsTile(
                          icon: Icons.backup_outlined,
                          title: l10n.backupRestoreSectionTitle,
                          subtitle: _backupOperationsSummary(l10n),
                          hasError: widget.viewModel.hasBackupOperationsError,
                          onTap: widget.viewModel.isSaving
                              ? null
                              : () => _openBackupOperations(context),
                        ),
                        PointySettingsTile(
                          icon: Icons.cloud_sync_outlined,
                          title: l10n.migrationTitle,
                          subtitle: l10n.migrationSubtitle,
                          onTap: widget.viewModel.isSaving
                              ? null
                              : () => _openDataMigration(context),
                        ),
                        PointySettingsTile(
                          icon: Icons.file_download_outlined,
                          title: l10n.analyticsExportSectionTitle,
                          subtitle: _analyticsExportSummary(l10n),
                          onTap: widget.viewModel.isExportingAnalytics
                              ? null
                              : () => _openAnalyticsExport(context),
                        ),
                        PointySettingsTile(
                          icon: Icons.currency_exchange_outlined,
                          title: l10n.exchangeRatesTitle,
                          subtitle: l10n.settlementInstrumentHelp,
                          onTap: () => _openExchangeRates(context),
                        ),
                        PointySettingsTile(
                          icon: Icons.workspace_premium_outlined,
                          title: l10n.subscriptionSectionTitle,
                          subtitle: l10n.subscriptionSectionSubtitle,
                          onTap: () => _openSubscriptionStatus(context),
                        ),
                      ],
                    ),
                    if (widget.viewModel.hasSaveError) ...[
                      SizedBox(height: spacing.md),
                      PointyErrorState(
                        title: l10n.shopSettingsSaveError,
                        icon: Icons.save_outlined,
                      ),
                    ],
                  ],
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
    );
  }

  String _shopIdentitySummary(AppLocalizations l10n) {
    final shopName = _shopNameController.text.trim();
    final logoStatus = _hasVisibleLogo
        ? l10n.shopLogoUploadedValue
        : l10n.shopLogoMissingValue;
    if (shopName.isEmpty) {
      return logoStatus;
    }
    return l10n.shopIdentitySummary(shopName, logoStatus);
  }

  bool get _hasVisibleLogo {
    return _selectedLogoUpload != null ||
        (!_removeLogo && _logoAttachment != null);
  }

  String _receiptSummary(AppLocalizations l10n) {
    final status = _autoPrintReceipts
        ? l10n.shopSettingsEnabledValue
        : l10n.shopSettingsDisabledValue;
    final onlineStatus = _enableOnlineInvoices
        ? l10n.shopSettingsEnabledValue
        : l10n.shopSettingsDisabledValue;
    final floor = _autoPrintFloorSummary(l10n);
    return [
      l10n.receiptSettingsSummary(status),
      ?floor,
      l10n.onlineInvoiceSettingSummary(onlineStatus),
    ].join('، ');
  }

  /// The auto-print floor, as the collapsed section shows it — null when the
  /// shop has set none, or when auto-print is off and a floor would hold back
  /// nothing.
  String? _autoPrintFloorSummary(AppLocalizations l10n) {
    if (!_autoPrintReceipts) {
      return null;
    }
    final lines = _parseAutoPrintMinLineCount();
    final total = _parseAutoPrintMinTotal();
    final parts = [
      if (lines != null) l10n.autoPrintFloorLinesValue(lines),
      if (total != null) formatMoney(total),
    ];
    if (parts.isEmpty) {
      return null;
    }
    return l10n.autoPrintFloorSummary(
      parts.join(' ${l10n.autoPrintFloorEitherJoiner} '),
    );
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
    final lossStatus = _preventSellingAtLoss
        ? l10n.shopSettingsEnabledValue
        : l10n.shopSettingsDisabledValue;
    return l10n.inventorySettingsSummary(count, status, lossStatus);
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
      _requireCardPaymentReceipt
          ? l10n.shopSettingsEnabledValue
          : l10n.shopSettingsDisabledValue,
      l10n.trustedCardTerminalCount(_trustedCardTerminalIds.length),
    );
  }

  String _analyticsExportSummary(AppLocalizations l10n) {
    final filters = [
      if (_analyticsOccurredFrom != null || _analyticsOccurredTo != null)
        l10n.analyticsExportDateRangeSummary(
          _formatOptionalDate(_analyticsOccurredFrom, l10n),
          _formatOptionalDate(_analyticsOccurredTo, l10n),
        ),
      if (_analyticsEventType.isNotEmpty)
        _analyticsEventTypeLabel(l10n, _analyticsEventType),
      if (_analyticsSeverity.isNotEmpty)
        _analyticsSeverityLabel(l10n, _analyticsSeverity),
      if (_analyticsSource.isNotEmpty)
        _analyticsSourceLabel(l10n, _analyticsSource),
      if (_analyticsSearchController.text.trim().isNotEmpty)
        _analyticsSearchController.text.trim(),
    ];
    if (filters.isEmpty) {
      return l10n.analyticsExportAllEventsSummary;
    }
    return filters.join('، ');
  }

  String _backupOperationsSummary(AppLocalizations l10n) {
    final status = widget.viewModel.backupStatus;
    final activeJob = status?.activeJob;
    if (activeJob != null && activeJob.isActive) {
      return l10n.backupJobRunningSummary(
        _backupOperationLabel(l10n, activeJob.operation),
        activeJob.progressPercent,
      );
    }
    if (status == null) {
      return l10n.backupStatusLoadingSummary;
    }
    if (!status.schedule.enabled) {
      return l10n.backupScheduleDisabledSummary;
    }
    final nextScheduledAt = status.schedule.nextScheduledAt;
    if (nextScheduledAt == null) {
      return l10n.backupScheduleMissingDestinationSummary;
    }
    return l10n.backupNextScheduledSummary(_formatDateTime(nextScheduledAt));
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
        logoAttachment: _removeLogo ? null : _logoAttachment,
        selectedLogoUpload: _selectedLogoUpload,
        hasLogoMarkedForRemoval: _removeLogo,
        onChanged: () => _refreshSettingsGroup(refresh),
        onLogoSelected: (upload) {
          setState(() {
            _selectedLogoUpload = upload;
            _removeLogo = false;
          });
          refresh();
        },
        onLogoCleared: () {
          setState(() {
            _selectedLogoUpload = null;
            _removeLogo = _logoAttachment != null;
          });
          refresh();
        },
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
        autoPrintMinLineCountController: _autoPrintMinLineCountController,
        autoPrintMinTotalController: _autoPrintMinTotalController,
        enableOnlineInvoices: _enableOnlineInvoices,
        enabled: !widget.viewModel.isSaving,
        onAutoPrintReceiptsChanged: (value) {
          setState(() => _autoPrintReceipts = value);
          refresh();
        },
        onEnableOnlineInvoicesChanged: (value) {
          setState(() => _enableOnlineInvoices = value);
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
        posCashPurchaseLimitController: _posCashPurchaseLimitController,
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
        trustedTerminalIds: _trustedCardTerminalIds,
        enabled: !widget.viewModel.isSaving,
        enableCashPayments: _enableCashPayments,
        enableCardPayments: _enableCardPayments,
        enableTransferPayments: _enableTransferPayments,
        requireCardPaymentReceipt: _requireCardPaymentReceipt,
        requireCustomerForCredit: _requireCustomerForCredit,
        enforceCustomerCreditLimits: _enforceCustomerCreditLimits,
        defaultCustomerCreditLimitController:
            _defaultCustomerCreditLimitController,
        defaultPaymentTermsDaysController: _defaultPaymentTermsDaysController,
        defaultPaymentTermsBasis: _defaultPaymentTermsBasis,
        onDefaultPaymentTermsBasisChanged: (basis) {
          if (basis == null) {
            return;
          }
          setState(() => _defaultPaymentTermsBasis = basis);
        },
        allowCashierCustomerAccess: _allowCashierCustomerAccess,
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
        onRequireCardReceiptChanged: (value) {
          setState(() => _requireCardPaymentReceipt = value);
          refresh();
        },
        onRequireCustomerForCreditChanged: (value) {
          setState(() => _requireCustomerForCredit = value);
          refresh();
        },
        onEnforceCustomerCreditLimitsChanged: (value) {
          setState(() => _enforceCustomerCreditLimits = value);
          refresh();
        },
        onAllowCashierCustomerAccessChanged: (value) {
          setState(() => _allowCashierCustomerAccess = value);
          refresh();
        },
        onEnableTransferChanged: (value) {
          setState(() => _enableTransferPayments = value);
          refresh();
        },
        onCommissionChanged: () => _refreshSettingsGroup(refresh),
        onManageTrustedTerminalIds: () {
          _manageTrustedCardTerminalIds(context, refresh);
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
      _InventorySettingsFields(
        controller: _lowStockThresholdController,
        enabled: !widget.viewModel.isSaving,
        errorText: _lowStockThresholdError(l10n),
        allowOverselling: _allowOverselling,
        warnLowStockBeforeSale: _warnLowStockBeforeSale,
        preventSellingAtLoss: _preventSellingAtLoss,
        valuationMethod: _inventoryValuationMethod,
        onValuationMethodChanged: (value) {
          setState(() => _inventoryValuationMethod = value);
          refresh();
        },
        onThresholdChanged: () => _refreshSettingsGroup(refresh),
        onAllowOversellingChanged: (value) {
          setState(() => _allowOverselling = value);
          refresh();
        },
        onWarnLowStockBeforeSaleChanged: (value) {
          setState(() => _warnLowStockBeforeSale = value);
          refresh();
        },
        onPreventSellingAtLossChanged: (value) {
          setState(() => _preventSellingAtLoss = value);
          refresh();
        },
        enablePurchaseSuggestions: _enablePurchaseSuggestions,
        onEnablePurchaseSuggestionsChanged: (value) {
          setState(() => _enablePurchaseSuggestions = value);
          refresh();
        },
      ),
    ];
  }

  List<Widget> _buildAnalyticsExportFields(
    BuildContext context,
    AppLocalizations l10n,
    VoidCallback refresh,
  ) {
    return [
      _AnalyticsExportFields(
        format: _analyticsExportFormat,
        occurredFrom: _analyticsOccurredFrom,
        occurredTo: _analyticsOccurredTo,
        eventType: _analyticsEventType,
        severity: _analyticsSeverity,
        source: _analyticsSource,
        searchController: _analyticsSearchController,
        platformController: _analyticsPlatformController,
        sessionController: _analyticsSessionController,
        deviceController: _analyticsDeviceController,
        enabled: !widget.viewModel.isExportingAnalytics,
        onFormatChanged: (value) {
          setState(() => _analyticsExportFormat = value);
          refresh();
        },
        onEventTypeChanged: (value) {
          setState(() => _analyticsEventType = value);
          refresh();
        },
        onSeverityChanged: (value) {
          setState(() => _analyticsSeverity = value);
          refresh();
        },
        onSourceChanged: (value) {
          setState(() => _analyticsSource = value);
          refresh();
        },
        onTextFilterChanged: () => _refreshSettingsGroup(refresh),
        onPickFrom: () => _pickAnalyticsDate(
          context,
          initialDate: _analyticsOccurredFrom,
          onPicked: (date) => setState(() => _analyticsOccurredFrom = date),
          refresh: refresh,
        ),
        onPickTo: () => _pickAnalyticsDate(
          context,
          initialDate: _analyticsOccurredTo,
          onPicked: (date) => setState(() => _analyticsOccurredTo = date),
          refresh: refresh,
        ),
        onClearDates: () {
          setState(() {
            _analyticsOccurredFrom = null;
            _analyticsOccurredTo = null;
          });
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
            final isCompactDialog =
                MediaQuery.sizeOf(context).width < AppBreakpoints.largePhoneMin;
            final daysField = DropdownButtonFormField<int>(
              initialValue: selectedDays,
              decoration: InputDecoration(
                labelText: l10n.cashierReturnWindowDaysLabel,
              ),
              items: [
                for (var value = 0; value <= 30; value++)
                  DropdownMenuItem<int>(value: value, child: Text('$value')),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setDialogState(() => selectedDays = value);
              },
            );
            final hoursField = DropdownButtonFormField<int>(
              initialValue: selectedHours,
              decoration: InputDecoration(
                labelText: l10n.cashierReturnWindowHoursLabel,
              ),
              items: [
                for (var value = 0; value < 24; value++)
                  DropdownMenuItem<int>(value: value, child: Text('$value')),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setDialogState(() => selectedHours = value);
              },
            );

            return AdaptiveDialogSurface(
              size: AdaptiveModalSize.compact,
              child: AlertDialog(
                icon: const Icon(Icons.schedule_outlined),
                title: Text(l10n.cashierReturnWindowDialogTitle),
                content: SizedBox(
                  width: 320,
                  child: isCompactDialog
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            daysField,
                            const SizedBox(height: 12),
                            hoursField,
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: daysField),
                            const SizedBox(width: 12),
                            Expanded(child: hoursField),
                          ],
                        ),
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
              ),
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

  Future<void> _manageTrustedCardTerminalIds(
    BuildContext context,
    VoidCallback refresh,
  ) async {
    final updatedTerminalIds = await showDialog<List<String>>(
      context: context,
      builder: (context) => _TrustedCardTerminalsDialog(
        initialTerminalIds: _trustedCardTerminalIds,
      ),
    );
    if (updatedTerminalIds == null) {
      return;
    }

    setState(() {
      _trustedCardTerminalIds = _normalizeTrustedTerminalIds(
        updatedTerminalIds,
      );
    });
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
                  final spacing = AdaptiveSpacing.of(context);

                  return PointyScaffold(
                    appBar: PointyAppBar(
                      title: Text(title),
                      isLoading: widget.viewModel.isSaving,
                    ),
                    body: Column(
                      children: [
                        Expanded(
                          child: ListView(
                            padding: spacing.pagePadding,
                            children: [
                              AdaptiveMaxWidth(
                                width: AppContentWidth.form,
                                child: PointyDetailSection(
                                  icon: icon,
                                  title: title,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
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
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openAnalyticsExport(BuildContext context) {
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
                  final spacing = AdaptiveSpacing.of(context);

                  return PointyScaffold(
                    appBar: PointyAppBar(
                      title: Text(l10n.analyticsExportTitle),
                      isLoading: widget.viewModel.isExportingAnalytics,
                    ),
                    body: Column(
                      children: [
                        Expanded(
                          child: ListView(
                            padding: spacing.pagePadding,
                            children: [
                              AdaptiveMaxWidth(
                                width: AppContentWidth.form,
                                child: PointyDetailSection(
                                  icon: Icons.file_download_outlined,
                                  title:
                                      l10n.analyticsExportFiltersSectionTitle,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: _buildAnalyticsExportFields(
                                      context,
                                      l10n,
                                      refreshRoute,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(height: spacing.lg),
                              // Deliberately under the export, not beside it:
                              // the only safe order is take a copy, then
                              // clear, and the layout should read that way.
                              AdaptiveMaxWidth(
                                width: AppContentWidth.form,
                                child: AnalyticsPurgeSection(
                                  viewModel: widget.viewModel,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _AnalyticsExportActionBar(
                          isExporting: widget.viewModel.isExportingAnalytics,
                          hasExportError:
                              widget.viewModel.hasAnalyticsExportError,
                          progress: widget.viewModel.analyticsExportProgress,
                          onCancel: widget.viewModel.canCancelAnalyticsExport
                              ? widget.viewModel.cancelAnalyticsExport
                              : null,
                          onSubmit: () {
                            _submitAnalyticsExport();
                            refreshRoute();
                          },
                        ),
                      ],
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

  Future<void> _openBackupOperations(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            _BackupOperationsPage(viewModel: widget.viewModel),
      ),
    );
  }

  Future<void> _openDataMigration(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            DataMigrationPage(viewModel: widget.migrationViewModel),
      ),
    );
  }

  Future<void> _openSalesChannels(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            SalesChannelsPage(viewModel: widget.salesChannelsViewModel),
      ),
    );
  }

  Future<void> _openWarehouses(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            WarehousesPage(viewModel: widget.warehousesViewModel),
      ),
    );
  }

  Future<void> _openTransfers(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => TransfersScreen(
          viewModel: widget.transfersViewModel,
          repository: widget.warehouseRepository,
        ),
      ),
    );
  }

  Future<void> _openPriceCheckers(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            PriceCheckersPage(viewModel: widget.priceCheckersViewModel),
      ),
    );
  }

  Future<void> _openScales(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScalesScreen(viewModel: widget.scalesViewModel),
      ),
    );
  }

  Future<void> _openCameraSettings(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => CameraSettingsPage(
          viewModel: widget.cameraSettingsViewModel,
          enableSurveillance:
              widget.viewModel.settings?.enableSurveillance ?? false,
          onToggleEnabled: (enabled) =>
              widget.viewModel.setSurveillanceEnabled(enabled),
        ),
      ),
    );
  }

  Future<void> _openAttendanceSettings(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            AttendanceSettingsPage(viewModel: widget.attendanceViewModel),
      ),
    );
  }

  Future<void> _openExchangeRates(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            ExchangeRatesPage(viewModel: widget.exchangeRatesViewModel),
      ),
    );
  }

  Future<void> _openSubscriptionStatus(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            SubscriptionStatusPage(viewModel: widget.subscriptionViewModel),
      ),
    );
  }

  Future<void> _openMessagingSettings(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) =>
            MessagingSettingsPage(viewModel: widget.messagingViewModel),
      ),
    );
  }

  Future<void> _openOperationsSettings(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => OperationsSettingsPage(
          shopSettingsViewModel: widget.viewModel,
          workflowsViewModel: widget.workflowsViewModel,
          assetTypesViewModel: widget.assetTypesViewModel,
          prepStationsViewModel: widget.prepStationsViewModel,
          modifierGroupsViewModel: widget.modifierGroupsViewModel,
        ),
      ),
    );
  }

  Future<void> _pickAnalyticsDate(
    BuildContext context, {
    required DateTime? initialDate,
    required ValueChanged<DateTime> onPicked,
    required VoidCallback refresh,
  }) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) {
      return;
    }

    onPicked(DateTime(picked.year, picked.month, picked.day));
    refresh();
  }

  Future<void> _submitAnalyticsExport() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final file = await widget.viewModel.exportAnalyticsEvents(
      AnalyticsExportQuery(
        format: _analyticsExportFormat,
        occurredFrom: _analyticsOccurredFrom,
        occurredTo: _analyticsOccurredTo?.add(const Duration(days: 1)),
        eventType: _analyticsEventType,
        severity: _analyticsSeverity,
        source: _analyticsSource,
        platform: _analyticsPlatformController.text,
        sessionId: _analyticsSessionController.text,
        deviceId: _analyticsDeviceController.text,
        search: _analyticsSearchController.text,
      ),
    );

    if (!mounted) {
      return;
    }

    // The export itself failed (the view model already surfaces the error in the
    // footer); still confirm it to the user so the tap doesn't feel ignored.
    if (file == null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.analyticsExportFailedMessage)),
        );
      return;
    }

    final result = await downloadAnalyticsExportFile(
      file,
      dialogTitle: l10n.analyticsExportSaveDialogTitle,
    );
    if (!result.isCanceled) {
      widget.viewModel.trackAnalyticsExportDownloadResult(
        file,
        downloaded: result.isSaved,
      );
    }

    final message = switch (result.status) {
      AnalyticsExportSaveStatus.saved =>
        result.location == null
            ? l10n.analyticsExportStartedMessage
            : l10n.analyticsExportSavedMessage(result.location!),
      AnalyticsExportSaveStatus.canceled => l10n.analyticsExportCanceledMessage,
      AnalyticsExportSaveStatus.failed => l10n.analyticsExportFailedMessage,
    };
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: result.isSaved && result.location != null
              ? const Duration(seconds: 6)
              : const Duration(seconds: 4),
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
    final draft = _buildDraft();
    var saved = await widget.viewModel.updateSettings(draft);

    // The backend holds back a change to how stock is costed until the user
    // has seen what it means. Ask, then re-send the same draft with the
    // acknowledgement attached.
    if (!saved && widget.viewModel.needsValuationMethodConfirmation) {
      if (!mounted) {
        return;
      }
      final confirmed = await _confirmValuationMethodChange(l10n);
      if (!confirmed) {
        // Put the form back on the stored method so the screen and the shop
        // agree about what is in force.
        setState(() {
          _inventoryValuationMethod =
              (widget.viewModel.settings ?? widget.settings)
                  .inventoryValuationMethod;
        });
        return;
      }
      saved = await widget.viewModel.updateSettings(
        draft.acknowledgingValuationMethodChange(),
      );
    }

    if (saved && _selectedLogoUpload != null) {
      saved = await widget.viewModel.uploadLogo(_selectedLogoUpload!);
    } else if (saved && _removeLogo) {
      saved = await widget.viewModel.removeLogo();
    }

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

  /// The payload this form sends: the stored settings, with this form's own
  /// controls applied over them.
  ///
  /// It starts from [ShopSettingsDraft.fromSettings] rather than listing every
  /// field, because a draft goes out as the whole payload. Assembling one from
  /// the controls means every setting that lives on another page — the
  /// operations modes, the kitchen-ticket switch, the camera settings — is sent
  /// as its *default* and quietly reset. Starting from the stored settings makes
  /// carrying them the default behaviour, including for fields added later.
  ShopSettingsDraft _buildDraft() {
    final currentSettings = widget.viewModel.settings ?? widget.settings;
    return ShopSettingsDraft.fromSettings(currentSettings).copyWith(
      shopName: _shopNameController.text.trim(),
      receiptHeader: _receiptHeaderController.text.trim(),
      receiptFooter: _receiptFooterController.text.trim(),
      enableOnlineInvoices: _enableOnlineInvoices,
      requireOpeningCash: _requireOpeningCash,
      autoPrintReceipts: _autoPrintReceipts,
      // Emptying either box clears that half of the floor, so both are passed
      // even when null — a value here, not an omission.
      autoPrintMinLineCount: _parseAutoPrintMinLineCount(),
      autoPrintMinTotal: _parseAutoPrintMinTotal(),
      allowOverselling: _allowOverselling,
      warnLowStockBeforeSale: _warnLowStockBeforeSale,
      preventSellingAtLoss: _preventSellingAtLoss,
      enablePurchaseSuggestions: _enablePurchaseSuggestions,
      lowStockThreshold:
          int.tryParse(_lowStockThresholdController.text.trim()) ?? 0,
      cashierReturnWindowHours: _cashierReturnWindowHours,
      enableCashPayments: _enableCashPayments,
      enableCardPayments: _enableCardPayments,
      enableTransferPayments: _enableTransferPayments,
      requireCardPaymentReceipt: _requireCardPaymentReceipt,
      trustedCardTerminalIds: _trustedCardTerminalIds,
      cardCommissionPercent: _parsePercent(_cardCommissionController.text),
      transferCommissionPercent: _parsePercent(
        _transferCommissionController.text,
      ),
      requireCustomerForCredit: _requireCustomerForCredit,
      enforceCustomerCreditLimits: _enforceCustomerCreditLimits,
      // Both money fields are cleared by emptying the box, so they are passed
      // even when null — that is a value here, not an omission.
      defaultCustomerCreditLimit: _parseDefaultCustomerCreditLimit(),
      // An emptied or unparseable box means zero days — due on issue — which is
      // the shop's state before it ever set a term, not an error to refuse.
      defaultPaymentTermsDays:
          int.tryParse(_defaultPaymentTermsDaysController.text.trim()) ?? 0,
      defaultPaymentTermsBasis: _defaultPaymentTermsBasis,
      allowCashierCustomerAccess: _allowCashierCustomerAccess,
      posCashPurchaseLimit: _parsePosCashPurchaseLimit(),
      inventoryValuationMethod: _inventoryValuationMethod,
    );
  }

  Future<bool> _confirmValuationMethodChange(AppLocalizations l10n) async {
    final current =
        (widget.viewModel.settings ?? widget.settings).inventoryValuationMethod;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: Text(l10n.valuationMethodChangeWarningTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.valuationMethodChangeWarningBody(
                  _valuationMethodLabel(l10n, current),
                  _valuationMethodLabel(l10n, _inventoryValuationMethod),
                ),
              ),
              const SizedBox(height: 12),
              Text(l10n.valuationMethodChangeWarningConsequences),
              const SizedBox(height: 12),
              Text(l10n.valuationMethodChangeWarningAdvice),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.valuationMethodChangeKeepCurrent),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.valuationMethodChangeConfirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  double _parsePercent(String value) {
    return parseDecimal(value) ?? 0;
  }

  static List<String> _normalizeTrustedTerminalIds(Iterable<String> values) {
    final ids = values
        .map((value) => value.trim().toUpperCase())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    ids.sort();
    return ids;
  }

  String _formatOptionalDate(DateTime? date, AppLocalizations l10n) {
    if (date == null) {
      return l10n.analyticsExportOpenDateValue;
    }
    return _formatDate(date);
  }

  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _formatDateTime(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.year}-$month-$day $hour:$minute';
  }
}
