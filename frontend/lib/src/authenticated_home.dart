import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'app_dependencies.dart';
import 'core/result.dart';
import 'core/authorization.dart';
import 'data/models/pos_user.dart';
import 'data/models/purchase_submission.dart';
import 'data/models/analytics_event.dart';
import 'data/models/business_alert.dart';
import 'data/models/analytics_export.dart';
import 'data/models/report_run.dart';
import 'data/models/sale_order.dart';
import 'data/models/shop_settings.dart';
import 'data/services/analytics_export_downloader.dart';
import 'data/services/barcode_label_print_preferences.dart';
import 'features/activity_log/views/activity_log_event_presenter.dart';
import 'features/activity_log/views/activity_log_screen.dart';
import 'features/ai/view_models/ai_chat_view_model.dart';
import 'features/ai/views/ai_assistant_screen.dart';
import 'features/catalog/view_models/catalog_view_model.dart';
import 'features/catalog/view_models/category_management_view_model.dart';
import 'features/catalog/views/category_management_screen.dart';
import 'features/catalog/views/catalog_screen.dart';
import 'features/contacts/views/contact_management_screen.dart';
import 'features/crm/views/campaigns_screen.dart';
import 'features/crm/views/conversations_screen.dart';
import 'features/dashboard/views/dashboard_screen.dart';
import 'features/fraud/view_models/integrity_monitor_view_model.dart';
import 'features/fraud/views/integrity_monitor_screen.dart';
import 'features/device_settings/views/device_settings_screen.dart';
import 'features/discounts/views/discount_management_screen.dart';
import 'features/employees/views/employee_payroll_screen.dart';
import 'features/expenses/view_models/expense_categories_view_model.dart';
import 'features/expenses/view_models/expenses_view_model.dart';
import 'features/expenses/views/expenses_screen.dart';
import 'features/invoices/views/invoice_details_screen.dart';
import 'features/returns_exchange/views/returns_exchange_lookup_screen.dart';
import 'features/invoices/views/invoice_list_screen.dart';
import 'features/notifications/views/notification_center_host.dart';
import 'features/assets/view_models/asset_details_view_model.dart';
import 'features/assets/view_models/assets_view_model.dart';
import 'features/assets/views/asset_details_screen.dart';
import 'features/assets/views/assets_screen.dart';
import 'features/operations/view_models/asset_types_view_model.dart';
import 'features/operations/view_models/job_details_view_model.dart';
import 'features/operations/view_models/job_history_view_model.dart';
import 'features/operations/view_models/jobs_board_view_model.dart';
import 'features/operations/view_models/recipes_view_model.dart';
import 'features/operations/view_models/workflows_view_model.dart';
import 'features/operations/views/job_details_screen.dart';
import 'features/operations/views/job_history_screen.dart';
import 'features/operations/views/jobs_screen.dart';
import 'features/payments/view_models/payments_hub_view_model.dart';
import 'features/payments/views/payments_hub_screen.dart';
import 'features/treasury/view_models/money_position_view_model.dart';
import 'features/treasury/views/money_position_screen.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';
import 'features/purchasing/views/purchase_order_details_screen.dart';
import 'features/purchasing/views/purchase_order_edit_screen.dart';
import 'features/purchasing/views/purchase_order_list_screen.dart';
import 'features/purchasing/views/purchasing_screen.dart';
import 'features/stock_count/views/stock_count_sessions_screen.dart';
import 'features/register_sessions/view_models/register_session_history_view_model.dart';
import 'features/register_sessions/views/register_session_history_screen.dart';
import 'features/reports/pdf/report_document_builder.dart';
import 'features/reports/pdf/report_pdf.dart';
import 'features/reports/views/report_pdf_preview_screen.dart';
import 'features/reports/views/reports_screen.dart';
import 'features/settings/view_models/modifier_groups_view_model.dart';
import 'features/settings/view_models/prep_stations_view_model.dart';
import 'features/settings/view_models/price_checkers_view_model.dart';
import 'features/settings/view_models/sales_channels_view_model.dart';
import 'features/settings/view_models/shop_settings_view_model.dart';
import 'features/settings/view_models/messaging_settings_view_model.dart';
import 'features/settings/view_models/exchange_rates_view_model.dart';
import 'features/settings/view_models/subscription_status_view_model.dart';
import 'features/settings/views/shop_settings_screen.dart';
import 'features/user_settings/views/user_settings_screen.dart';
import 'features/users/view_models/user_management_view_model.dart';
import 'features/users/view_models/user_details_view_model.dart';
import 'features/users/view_models/user_permissions_view_model.dart';
import 'features/users/views/user_details_screen.dart';
import 'features/users/views/user_management_screen.dart';
import 'features/users/views/user_permissions_screen.dart';
import 'data/models/barcode_label.dart';
import 'data/models/contact.dart';
import 'data/models/product.dart';
import 'data/models/product_page.dart';
import 'data/models/product_query.dart';
import 'data/models/sale_order_page.dart';
import 'features/catalog/view_models/product_stock_view_model.dart';
import 'features/catalog/views/product_variant_details_screen.dart';
import 'features/contacts/views/customer_details_screen.dart';
import 'features/contacts/views/supplier_details_screen.dart';
import 'shared/async_selection/async_multi_select_picker.dart';
import 'shared/command_palette/command_palette.dart';
import 'shared/formatters.dart';
import 'shared/navigation/ai_deep_link.dart';
import 'shared/navigation/app_navigation.dart';
import 'core/analytics_screen_tracker.dart';

class AuthenticatedHome extends StatelessWidget {
  const AuthenticatedHome({
    super.key,
    required this.dependencies,
    required this.currentUser,
  });

  final PointyAppDependencies dependencies;
  final PosUser currentUser;

  @override
  Widget build(BuildContext context) {
    final routes = _AuthenticatedRoutes(
      dependencies: dependencies,
      currentUser: currentUser,
      capabilities: AuthorizationCapabilities.forUser(currentUser),
    );
    // Home follows the user's main responsibility: managers see the
    // dashboard, register staff the POS, and workshop-only roles
    // (technicians) land directly on the jobs board.
    final capabilities = routes.capabilities;
    final home = capabilities.canViewDashboard
        ? routes.buildDashboardScreen(context)
        : capabilities.canAccessPos
        ? routes.buildPosScreen(context)
        : capabilities.canViewOperations
        ? routes.operationsRouteBuilder(context)
        : routes.buildPosScreen(context);
    return CommandPaletteScope(
      key: commandPaletteScopeKey,
      sources: routes.buildCommandSources(context),
      child: NotificationCenterHost(
        viewModel: dependencies.notificationCenterViewModel,
        onOpenAlert: routes.openBusinessAlert,
        child: home,
      ),
    );
  }
}

/// Builds every top-level screen and implements [AppNavigation], so the
/// drawer/rail on each screen navigates through one place with one set of
/// rules instead of per-screen callback wiring.
class _AuthenticatedRoutes implements AppNavigation {
  const _AuthenticatedRoutes({
    required this.dependencies,
    required this.currentUser,
    required this.capabilities,
  });

  final PointyAppDependencies dependencies;

  @override
  final PosUser currentUser;

  @override
  final AuthorizationCapabilities capabilities;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {
    if (destination == from) {
      return;
    }
    if (!isDestinationAvailable(destination)) {
      return;
    }
    switch (destination) {
      case AppNavigationDestination.dashboard:
        openDashboard(context);
      case AppNavigationDestination.pos:
        openPos(context);
      default:
        _openDestinationScreen(context, destination, from: from);
    }
  }

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {
    if (!isDestinationAvailable(AppNavigationDestination.aiAssistant)) {
      return;
    }
    _openDestinationScreen(
      context,
      AppNavigationDestination.aiAssistant,
      from: from,
      builder: (routeContext) => _buildAiAssistant(
        routeContext,
        seedPrompt: seedPrompt,
        autoSend: autoSend,
      ),
    );
  }

  @override
  void logout(BuildContext context) {
    commandPaletteRecents.clear();
    Navigator.of(context).popUntil((route) => route.isFirst);
    dependencies.authViewModel.logout();
  }

  /// Uniform stack semantics: sections are pushed over the home route and
  /// replace each other afterwards, so the stack never grows past
  /// [home, section] — except when leaving the POS workspace, which stays on
  /// the stack so the cashier can return to an untouched sale.
  void _openDestinationScreen(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
    WidgetBuilder? builder,
  }) {
    final routeBuilder = builder ?? _destinationRouteBuilder(destination);
    if (from == AppNavigationDestination.pos) {
      unawaited(_pushFromPos(context, destination, routeBuilder));
      return;
    }
    if (ModalRoute.of(context)?.isFirst ?? false) {
      push(context, routeBuilder);
      return;
    }
    replace(context, routeBuilder);
  }

  Future<void> _pushFromPos(
    BuildContext context,
    AppNavigationDestination destination,
    WidgetBuilder builder,
  ) async {
    await push(context, builder);
    // Back on the POS workspace: refresh whatever the visited screen may
    // have changed before the cashier resumes selling.
    switch (destination) {
      case AppNavigationDestination.catalog:
        await dependencies.posViewModel.loadCatalog();
      case AppNavigationDestination.settings:
        await dependencies.posViewModel.loadCheckoutSettings();
      default:
        break;
    }
  }

  WidgetBuilder _destinationRouteBuilder(AppNavigationDestination destination) {
    return switch (destination) {
      AppNavigationDestination.userSettings => userSettingsRouteBuilder,
      AppNavigationDestination.aiAssistant => aiAssistantRouteBuilder,
      AppNavigationDestination.operations => operationsRouteBuilder,
      AppNavigationDestination.assets => assetsRouteBuilder,
      AppNavigationDestination.invoices => invoicesRouteBuilder,
      AppNavigationDestination.returnsExchange => returnsExchangeRouteBuilder,
      AppNavigationDestination.purchasing => purchasingRouteBuilder,
      AppNavigationDestination.contacts => contactsRouteBuilder,
      AppNavigationDestination.conversations => conversationsRouteBuilder,
      AppNavigationDestination.campaigns => campaignsRouteBuilder,
      AppNavigationDestination.catalog => catalogRouteBuilder,
      AppNavigationDestination.categories => categoryRouteBuilder,
      AppNavigationDestination.stockCount => stockCountRouteBuilder,
      AppNavigationDestination.registerSessions => registerSessionsRouteBuilder,
      AppNavigationDestination.employees => employeePayrollRouteBuilder,
      AppNavigationDestination.expenses => expensesRouteBuilder,
      AppNavigationDestination.payments => paymentsRouteBuilder,
      AppNavigationDestination.discounts => discountsRouteBuilder,
      AppNavigationDestination.reports => reportsRouteBuilder,
      AppNavigationDestination.activityLog => activityLogRouteBuilder,
      AppNavigationDestination.deviceSettings => deviceSettingsRouteBuilder,
      AppNavigationDestination.users => usersRouteBuilder,
      AppNavigationDestination.settings => shopSettingsRouteBuilder,
      AppNavigationDestination.dashboard ||
      AppNavigationDestination.pos => throw StateError(
        'dashboard and pos are handled directly by navigateTo',
      ),
    };
  }

  Widget buildDashboardScreen(BuildContext context) {
    return dashboardRouteBuilder(context);
  }

  Widget buildPosScreen(BuildContext context) {
    return _screen(
      'pos',
      PosScreen(
        viewModel: dependencies.posViewModel,
        contactRepository: dependencies.contactRepository,
        printingRepository: dependencies.printingRepository,
        shopSettingsRepository: dependencies.shopSettingsRepository,
        catalogRepository: dependencies.catalogRepository,
        purchaseRepository: dependencies.purchaseRepository,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget dashboardRouteBuilder(BuildContext routeContext) {
    return _screen(
      'dashboard',
      DashboardScreen(
        viewModel: dependencies.dashboardViewModel,
        capabilities: capabilities,
        navigation: this,
        onOpenIntegrityMonitor: capabilities.actionFor(
          AppCapability.viewFraudFindings,
          () => openIntegrityMonitor(routeContext),
        ),
      ),
    );
  }

  Widget posRouteBuilder(BuildContext routeContext) {
    return buildPosScreen(routeContext);
  }

  Widget operationsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'operations',
      JobsScreen(
        viewModel: JobsBoardViewModel(
          dependencies.operationsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        capabilities: capabilities,
        navigation: this,
        currentUser: currentUser,
        contactRepository: dependencies.contactRepository,
        operationsRepository: dependencies.operationsRepository,
        catalogRepository: dependencies.catalogRepository,
        shopSettingsRepository: dependencies.shopSettingsRepository,
        recipesViewModel: RecipesViewModel(
          dependencies.operationsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        onOpenHistory: () {
          push(
            routeContext,
            (_) => _screen(
              'job_history',
              JobHistoryScreen(
                viewModel: JobHistoryViewModel(
                  dependencies.operationsRepository,
                ),
                onOpenJob: (job) => openJobDetails(routeContext, job.id),
              ),
            ),
          );
        },
        onOpenJob: (job) => openJobDetails(routeContext, job.id),
      ),
    );
  }

  /// Opens one job. Takes an id rather than a loaded job so the board, the
  /// history list and an asset's service record can all land on the same screen.
  void openJobDetails(BuildContext routeContext, int jobId) {
    push(
      routeContext,
      (_) => _screen(
        'job_details',
        JobDetailsScreen(
          viewModel: JobDetailsViewModel(
            dependencies.operationsRepository,
            jobId: jobId,
            analyticsEngine: dependencies.analyticsEngine,
          ),
          capabilities: capabilities,
          currentUser: currentUser,
          catalogRepository: dependencies.catalogRepository,
          operationsRepository: dependencies.operationsRepository,
          employeeRepository: dependencies.employeeRepository,
        ),
      ),
    );
  }

  Widget assetsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'assets',
      AssetsScreen(
        viewModel: AssetsViewModel(dependencies.operationsRepository),
        capabilities: capabilities,
        navigation: this,
        onOpenAsset: (asset) => openAssetDetails(routeContext, asset.id),
      ),
    );
  }

  /// Opens one item's registry page. Takes an id rather than a loaded asset so
  /// a job's device chip and the assets list can both land on the same screen.
  void openAssetDetails(BuildContext routeContext, int assetId) {
    push(
      routeContext,
      (_) => _screen(
        'asset_details',
        AssetDetailsScreen(
          viewModel: AssetDetailsViewModel(
            dependencies.operationsRepository,
            assetId: assetId,
          ),
          capabilities: capabilities,
          contactRepository: dependencies.contactRepository,
        ),
      ),
    );
  }

  Widget catalogRouteBuilder(BuildContext routeContext) {
    return _screen(
      'catalog',
      CatalogScreen(
        viewModel: CatalogViewModel(
          dependencies.catalogRepository,
          analyticsEngine: dependencies.analyticsEngine,
          fxRepository: dependencies.fxRepository,
        ),
        inventoryRepository: dependencies.inventoryRepository,
        printingRepository: dependencies.printingRepository,
        purchaseRepository: dependencies.purchaseRepository,
        saleRepository: dependencies.saleRepository,
        shopSettingsRepository: dependencies.shopSettingsRepository,
        contactRepository: dependencies.contactRepository,
        capabilities: capabilities,
        analyticsEngine: dependencies.analyticsEngine,
        navigation: this,
      ),
    );
  }

  Widget categoryRouteBuilder(BuildContext routeContext) {
    return _screen(
      'categories',
      CategoryManagementScreen(
        viewModel: CategoryManagementViewModel(
          dependencies.catalogRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        navigation: this,
      ),
    );
  }

  Widget registerSessionsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'register_sessions',
      RegisterSessionHistoryScreen(
        viewModel: RegisterSessionHistoryViewModel(
          dependencies.registerSessionRepository,
          dependencies.saleRepository,
          printingRepository: dependencies.printingRepository,
          shopSettingsRepository: dependencies.shopSettingsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        contactRepository: dependencies.contactRepository,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget invoicesRouteBuilder(BuildContext routeContext) {
    return _screen(
      'invoices',
      InvoiceListScreen(
        viewModel: dependencies.invoiceListViewModel,
        contactRepository: dependencies.contactRepository,
        capabilities: capabilities,
        navigation: this,
        onOpenInvoice: guardedSaleOrderAction(AppCapability.viewInvoices, (
          order,
        ) async {
          await push(
            routeContext,
            (context) => _screen(
              'invoice_details',
              InvoiceDetailsScreen(
                saleRepository: dependencies.saleRepository,
                printingRepository: dependencies.printingRepository,
                shopSettingsRepository: dependencies.shopSettingsRepository,
                catalogRepository: dependencies.catalogRepository,
                contactRepository: dependencies.contactRepository,
                initialOrder: order,
                capabilities: capabilities,
                analyticsEngine: dependencies.analyticsEngine,
              ),
            ),
          );
          await dependencies.invoiceListViewModel.loadInvoices();
        }),
        detailPaneBuilder: (context, order) => InvoiceDetailsView(
          saleRepository: dependencies.saleRepository,
          printingRepository: dependencies.printingRepository,
          shopSettingsRepository: dependencies.shopSettingsRepository,
          catalogRepository: dependencies.catalogRepository,
          contactRepository: dependencies.contactRepository,
          initialOrder: order,
          capabilities: capabilities,
          analyticsEngine: dependencies.analyticsEngine,
          showHeader: true,
        ),
      ),
    );
  }

  Widget returnsExchangeRouteBuilder(BuildContext routeContext) {
    return _screen(
      'returns_exchange',
      ReturnsExchangeLookupScreen(
        saleRepository: dependencies.saleRepository,
        printingRepository: dependencies.printingRepository,
        shopSettingsRepository: dependencies.shopSettingsRepository,
        catalogRepository: dependencies.catalogRepository,
        capabilities: capabilities,
        analyticsEngine: dependencies.analyticsEngine,
      ),
    );
  }

  Widget usersRouteBuilder(BuildContext routeContext) {
    return _screen(
      'users',
      UserManagementScreen(
        viewModel: UserManagementViewModel(
          dependencies.userRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        currentUser: currentUser,
        capabilities: capabilities,
        navigation: this,
        onOpenUserPermissions: (user) =>
            _openUserPermissions(routeContext, user),
        onOpenUserDetails: guardedValueAction(AppCapability.manageUsers, (
          user,
        ) {
          push(
            routeContext,
            (_) => _screen(
              'user_details',
              UserDetailsScreen(
                viewModel: UserDetailsViewModel(
                  dependencies.userRepository,
                  initialUser: user,
                ),
                capabilities: capabilities,
                onManagePermissions: (target) =>
                    _openUserPermissions(routeContext, target),
              ),
            ),
          );
        }),
      ),
    );
  }

  Future<bool> _openUserPermissions(BuildContext context, PosUser user) async {
    if (!capabilities.allows(AppCapability.manageUsers)) {
      return false;
    }
    final updated = await push<PosUser>(
      context,
      (_) => _screen(
        'user_permissions',
        UserPermissionsScreen(
          viewModel: UserPermissionsViewModel(
            dependencies.userRepository,
            user: user,
          ),
        ),
      ),
    );
    return updated != null;
  }

  Widget employeePayrollRouteBuilder(BuildContext routeContext) {
    return _screen(
      'employees',
      EmployeePayrollScreen(
        viewModel: dependencies.employeePayrollViewModel,
        attendanceViewModel: dependencies.attendanceViewModel,
        userRepository: dependencies.userRepository,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget aiAssistantRouteBuilder(BuildContext routeContext) =>
      _buildAiAssistant(routeContext);

  /// Builds the AI assistant screen, optionally seeded by a proactive hint that
  /// pre-fills (and maybe auto-sends) [seedPrompt]. The drawer-launched route
  /// passes neither, so it opens blank as before.
  Widget _buildAiAssistant(
    BuildContext routeContext, {
    String? seedPrompt,
    bool autoSend = false,
  }) {
    return _screen(
      'ai_assistant',
      AiAssistantScreen(
        viewModel: AiChatViewModel(dependencies.aiChatRepository),
        navigation: this,
        productSearch: _aiProductSearch,
        onOpenAiLink: openAiLink,
        initialPrompt: seedPrompt,
        autoSendInitialPrompt: autoSend,
      ),
    );
  }

  /// Loads products for the AI's product_picker question — keyed by each
  /// product's default VARIANT id (what a purchase-order line references), so the
  /// answer the AI receives is directly usable.
  Future<AsyncSelectionPage<int>> _aiProductSearch(
    String search,
    int page,
  ) async {
    final result = await dependencies.catalogRepository.loadProducts(
      query: ProductQuery(
        search: search,
        availability: ProductAvailabilityFilter.active,
      ),
      page: page,
    );
    return switch (result) {
      Ok(value: final productPage) => AsyncSelectionPage<int>(
        options: [
          for (final product in productPage.products)
            if (product.variantId != null)
              AsyncSelectionOption<int>(
                id: product.variantId!,
                label: product.name,
                subtitle: [
                  if (product.effectiveSku.isNotEmpty) product.effectiveSku,
                  if (product.effectiveBarcode.isNotEmpty)
                    product.effectiveBarcode,
                ].join(' • '),
              ),
        ],
        hasMore: productPage.hasMore,
      ),
      Error() => throw Exception('ai product search failed'),
    };
  }

  Widget expensesRouteBuilder(BuildContext routeContext) {
    return _screen(
      'expenses',
      ExpensesScreen(
        viewModel: ExpensesViewModel(
          dependencies.expenseRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        categoriesViewModel: ExpenseCategoriesViewModel(
          dependencies.expenseRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  /// الخزينة — the money position. This route used to open the payment ledger,
  /// which listed individual payments the expenses screen already covered. The
  /// ledger is still reachable from here for row-level proof and reprints; the
  /// route itself now answers the question the screen is named after.
  Widget paymentsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'money_position',
      MoneyPositionScreen(
        viewModel: MoneyPositionViewModel(dependencies.treasuryRepository),
        capabilities: capabilities,
        navigation: this,
        onOpenPaymentsLedger: () => _openPaymentsLedger(routeContext),
      ),
    );
  }

  void _openPaymentsLedger(BuildContext routeContext) {
    Navigator.of(routeContext).push(
      MaterialPageRoute<void>(
        builder: (_) => _screen(
          'payments_hub',
          PaymentsHubScreen(
            viewModel: PaymentsHubViewModel(dependencies.paymentsRepository),
            printingRepository: dependencies.printingRepository,
            shopSettingsRepository: dependencies.shopSettingsRepository,
            capabilities: capabilities,
            navigation: this,
          ),
        ),
      ),
    );
  }

  Widget shopSettingsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'shop_settings',
      ShopSettingsScreen(
        viewModel: ShopSettingsViewModel(
          dependencies.shopSettingsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        assetTypesViewModel: AssetTypesViewModel(
          dependencies.operationsRepository,
        ),
        salesChannelsViewModel: SalesChannelsViewModel(
          dependencies.salesChannelRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        priceCheckersViewModel: PriceCheckersViewModel(
          dependencies.priceCheckerRepository,
        ),
        workflowsViewModel: WorkflowsViewModel(
          dependencies.operationsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        prepStationsViewModel: PrepStationsViewModel(
          dependencies.prepStationRepository,
          dependencies.catalogRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        modifierGroupsViewModel: ModifierGroupsViewModel(
          dependencies.modifierGroupRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        attendanceViewModel: dependencies.attendanceViewModel,
        migrationViewModel: dependencies.migrationViewModel,
        subscriptionViewModel: SubscriptionStatusViewModel(
          dependencies.subscriptionRepository,
        ),
        exchangeRatesViewModel: ExchangeRatesViewModel(
          dependencies.fxRepository,
        ),
        messagingViewModel: MessagingSettingsViewModel(
          dependencies.messagingRepository,
        ),
        clientUpdateService: dependencies.clientUpdateService,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget userSettingsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'user_settings',
      UserSettingsScreen(
        viewModel: dependencies.userSettingsViewModel,
        currentUser: currentUser,
        onUserChanged: dependencies.authViewModel.replaceCurrentUser,
        navigation: this,
      ),
    );
  }

  Widget discountsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'discounts',
      DiscountManagementScreen(
        viewModel: dependencies.discountManagementViewModel,
        catalogRepository: dependencies.catalogRepository,
        contactRepository: dependencies.contactRepository,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget reportsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'reports',
      ReportsScreen(
        capabilities: capabilities,
        navigation: this,
        viewModel: dependencies.reportsViewModel,
        contactRepository: dependencies.contactRepository,
        onPreviewPdf: (run) => previewReport(routeContext, run),
        onPrintReport: (run) => printReport(routeContext, run),
        onExportArchive: (run) => shareReport(routeContext, run),
        onSaveCsv: () => saveReportCsv(routeContext),
      ),
    );
  }

  Widget activityLogRouteBuilder(BuildContext routeContext) {
    return _screen(
      'activity_log',
      ActivityLogScreen(
        viewModel: dependencies.activityLogViewModel,
        capabilities: capabilities,
        navigation: this,
        onOpenTarget: _openActivityTarget,
      ),
    );
  }

  Widget conversationsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'conversations',
      ConversationsScreen(
        viewModel: dependencies.conversationsViewModel,
        capabilities: capabilities,
        navigation: this,
        contactRepository: dependencies.contactRepository,
      ),
    );
  }

  Widget campaignsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'campaigns',
      CampaignsScreen(
        viewModel: dependencies.campaignsViewModel,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget deviceSettingsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'device_settings',
      DeviceSettingsScreen(
        deviceSettingsViewModel: dependencies.deviceSettingsViewModel,
        printingSettingsViewModel: dependencies.printingSettingsViewModel,
        printingRepository: dependencies.printingRepository,
        prepStationRepository: dependencies.prepStationRepository,
        priceCheckerController: dependencies.priceCheckerModeController,
        priceCheckerRepository: dependencies.priceCheckerRepository,
        analyticsEngine: dependencies.analyticsEngine,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget contactsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'contacts',
      ContactManagementScreen(
        viewModel: dependencies.contactManagementViewModel,
        purchaseRepository: dependencies.purchaseRepository,
        printingRepository: dependencies.printingRepository,
        shopSettingsRepository: dependencies.shopSettingsRepository,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget purchasingRouteBuilder(BuildContext routeContext) {
    return _screen(
      'purchase_orders',
      PurchaseOrderListScreen(
        viewModel: dependencies.purchaseOrderListViewModel,
        contactRepository: dependencies.contactRepository,
        capabilities: capabilities,
        navigation: this,
        onCreatePurchaseOrder: guardedAction(
          AppCapability.createPurchaseOrder,
          () async {
            dependencies.purchaseViewModel.clearDraft(trackLineDeletes: false);
            await push(routeContext, createPurchaseOrderRouteBuilder);
            await dependencies.purchaseOrderListViewModel.loadOrders();
          },
        ),
        onOpenPurchaseOrder: guardedPurchaseOrderAction(
          AppCapability.accessPurchasing,
          (order) async {
            await push(
              routeContext,
              (context) => _screen(
                'purchase_order_details',
                PurchaseOrderDetailsScreen(
                  purchaseRepository: dependencies.purchaseRepository,
                  printingRepository: dependencies.printingRepository,
                  shopSettingsRepository: dependencies.shopSettingsRepository,
                  initialOrder: order,
                  capabilities: capabilities,
                  onEditDraft: capabilities.canEditDraftPurchaseOrder
                      ? (draft) =>
                            openPurchaseOrderEditor(routeContext, draft.id)
                      : null,
                ),
              ),
            );
            await dependencies.purchaseOrderListViewModel.loadOrders();
          },
        ),
        onEditPurchaseOrder: guardedPurchaseOrderAction(
          AppCapability.editDraftPurchaseOrder,
          (order) async {
            await openPurchaseOrderEditor(routeContext, order.id);
            await dependencies.purchaseOrderListViewModel.loadOrders();
          },
        ),
      ),
    );
  }

  Widget stockCountRouteBuilder(BuildContext routeContext) {
    return _screen(
      'stock_counts',
      StockCountSessionsScreen(
        viewModel: dependencies.stockCountSessionsViewModel,
        stockCountRepository: dependencies.stockCountRepository,
        catalogRepository: dependencies.catalogRepository,
        capabilities: capabilities,
        navigation: this,
      ),
    );
  }

  Widget createPurchaseOrderRouteBuilder(BuildContext routeContext) {
    return _screen(
      'purchase_create',
      PurchasingScreen(
        viewModel: dependencies.purchaseViewModel,
        contactRepository: dependencies.contactRepository,
        capabilities: capabilities,
        navigation: this,
        showBackButton: true,
      ),
    );
  }

  /// Reopens a draft purchase [orderId] in the purchasing screen for editing,
  /// in its own isolated, non-persisted workspace. Completes when the editor is
  /// dismissed so callers can refresh.
  Future<void> openPurchaseOrderEditor(BuildContext context, int orderId) {
    return push(
      context,
      (_) => _screen(
        'purchase_edit',
        PurchaseOrderEditScreen(
          purchaseOrderId: orderId,
          catalogRepository: dependencies.catalogRepository,
          purchaseRepository: dependencies.purchaseRepository,
          contactRepository: dependencies.contactRepository,
          analyticsEngine: dependencies.analyticsEngine,
          capabilities: capabilities,
          navigation: this,
        ),
      ),
    );
  }

  Future<void> openBusinessAlert(
    BuildContext context,
    BusinessAlert alert,
  ) async {
    if (alert.type == BusinessAlertType.payrollReady) {
      if (!capabilities.canViewPayroll) {
        return;
      }
      final navigator = Navigator.of(context);
      navigator.pop();
      navigator.pushReplacement(
        MaterialPageRoute<void>(builder: employeePayrollRouteBuilder),
      );
      return;
    }

    final query = alert.investigationActivityQuery();
    if (query == null || !capabilities.canViewActivityLog) {
      return;
    }

    final navigator = Navigator.of(context);
    navigator.pop();
    await dependencies.activityLogViewModel.applyInvestigationQuery(
      query,
      reason: alert.investigationReason,
    );
    navigator.pushReplacement(
      MaterialPageRoute<void>(builder: activityLogRouteBuilder),
    );
  }

  Future<void> _openActivityTarget(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    switch (target.type) {
      case ActivityLogDrillDownType.saleOrder:
        final result = await dependencies.saleRepository.loadOrder(target.id);
        if (!context.mounted) {
          return;
        }
        switch (result) {
          case Ok<SaleOrder>():
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => InvoiceDetailsScreen(
                  saleRepository: dependencies.saleRepository,
                  printingRepository: dependencies.printingRepository,
                  shopSettingsRepository: dependencies.shopSettingsRepository,
                  catalogRepository: dependencies.catalogRepository,
                  contactRepository: dependencies.contactRepository,
                  initialOrder: result.value,
                  capabilities: capabilities,
                  analyticsEngine: dependencies.analyticsEngine,
                ),
              ),
            );
          case Error<SaleOrder>():
            messenger.showSnackBar(
              SnackBar(content: Text(l10n.activityLogOpenTargetError)),
            );
        }
      case ActivityLogDrillDownType.purchaseOrder:
        final result = await dependencies.purchaseRepository.loadPurchaseOrder(
          target.id,
        );
        if (!context.mounted) {
          return;
        }
        switch (result) {
          case Ok<PurchaseOrder>():
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PurchaseOrderDetailsScreen(
                  purchaseRepository: dependencies.purchaseRepository,
                  printingRepository: dependencies.printingRepository,
                  shopSettingsRepository: dependencies.shopSettingsRepository,
                  initialOrder: result.value,
                  capabilities: capabilities,
                  onEditDraft: capabilities.canEditDraftPurchaseOrder
                      ? (draft) => openPurchaseOrderEditor(context, draft.id)
                      : null,
                ),
              ),
            );
          case Error<PurchaseOrder>():
            messenger.showSnackBar(
              SnackBar(content: Text(l10n.activityLogOpenTargetError)),
            );
        }
    }
  }

  /// Names a screen for analytics. [TrackedScreen] owns *when* that takes
  /// effect — on mount and on returning from a pushed route, never on a plain
  /// rebuild. This used to call setCurrentScreen inline during build, which
  /// both missed the way back (a scan on the POS after visiting the invoice
  /// list was filed under `invoices`) and fired on rebuilds that were not
  /// navigation at all.
  Widget _screen(String screenName, Widget child) {
    return TrackedScreen(
      name: screenName,
      onEnter: _trackScreenView,
      child: child,
    );
  }

  void _trackScreenView(String screenName, ScreenEntry entry) {
    unawaited(
      dependencies.analyticsEngine.trackUsage(
        AnalyticsEventName.frontendScreenViewed,
        attributes: {
          'screen': screenName,
          'role': currentUser.role.toJson(),
          // Returning to a screen is a view too, but it is a new kind of one:
          // this event previously could not see it at all. Tagged so a count
          // of first arrivals is still recoverable.
          'entry': entry.name,
        },
      ),
    );
  }

  VoidCallback guardedAction(AppCapability capability, VoidCallback action) {
    return capabilities.actionFor(capability, action) ?? () {};
  }

  void Function(T value) guardedValueAction<T>(
    AppCapability capability,
    void Function(T value) action,
  ) {
    return capabilities.allows(capability) ? action : (_) {};
  }

  ValueChanged<PurchaseOrder> guardedPurchaseOrderAction(
    AppCapability capability,
    ValueChanged<PurchaseOrder> action,
  ) {
    return capabilities.allows(capability) ? action : (_) {};
  }

  ValueChanged<SaleOrder> guardedSaleOrderAction(
    AppCapability capability,
    ValueChanged<SaleOrder> action,
  ) {
    return capabilities.allows(capability) ? action : (_) {};
  }

  Future<T?> push<T>(BuildContext context, WidgetBuilder builder) {
    return Navigator.of(
      context,
    ).push<T>(MaterialPageRoute<T>(builder: builder));
  }

  void replace(BuildContext context, WidgetBuilder builder) {
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute<void>(builder: builder));
  }

  void openDashboard(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void openPos(BuildContext context) {
    if (!capabilities.canViewDashboard) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    final route = ModalRoute.of(context);
    if (route?.isFirst ?? false) {
      push(context, posRouteBuilder);
      return;
    }
    replace(context, posRouteBuilder);
  }

  void openIntegrityMonitor(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => IntegrityMonitorScreen(
          viewModel: IntegrityMonitorViewModel(
            dependencies.fraudRepository,
            analyticsEngine: dependencies.analyticsEngine,
          ),
          capabilities: capabilities,
          onOpenActivityLog: capabilities.canViewActivityLog
              ? () => push(context, activityLogRouteBuilder)
              : null,
        ),
      ),
    );
  }

  Future<void> previewReport(BuildContext context, ReportRun run) async {
    final document = await buildReportDocument(context, run);
    if (document == null || !context.mounted) {
      return;
    }
    unawaited(
      dependencies.analyticsEngine.trackUsage(
        AnalyticsEventName.reportPreviewed,
        attributes: _reportAttributes(run),
      ),
    );
    unawaited(push(context, (_) => ReportPdfPreviewScreen(document: document)));
  }

  Future<void> printReport(BuildContext context, ReportRun run) async {
    final document = await buildReportDocument(context, run);
    if (document == null || !context.mounted) {
      return;
    }
    final printed = await const ReportPrintingService().print(document);
    if (printed && context.mounted) {
      unawaited(
        dependencies.analyticsEngine.trackUsage(
          AnalyticsEventName.reportPrinted,
          attributes: _reportAttributes(run),
        ),
      );
      _showReportMessage(
        context,
        AppLocalizations.of(context)!.reportPrintQueuedMessage,
      );
    }
  }

  Future<void> shareReport(BuildContext context, ReportRun run) async {
    final document = await buildReportDocument(context, run);
    if (document == null || !context.mounted) {
      return;
    }
    final shared = await const ReportPrintingService().share(document);
    if (shared && context.mounted) {
      unawaited(
        dependencies.analyticsEngine.trackUsage(
          AnalyticsEventName.reportShared,
          attributes: _reportAttributes(run),
        ),
      );
      _showReportMessage(
        context,
        AppLocalizations.of(context)!.reportArchiveSharedMessage,
      );
    }
  }

  /// Exports the selected report as CSV and hands it to the platform's save
  /// dialog. Returns the message to show, or null when the user dismissed it.
  ///
  /// The export is streamed and stored nowhere: it runs at row caps far above
  /// what belongs in a saved run, and writing that into the run table on every
  /// click would grow the database by the size of the shop's history.
  Future<String?> saveReportCsv(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = dependencies.reportsViewModel;
    final file = await viewModel.exportCsv();
    if (file == null || !context.mounted) {
      return null;
    }
    unawaited(
      dependencies.analyticsEngine.trackUsage(
        AnalyticsEventName.reportShared,
        attributes: {
          'report_type': reportRunTypeToJson(viewModel.selectedType),
          'format': 'csv',
          'source': 'reports_screen',
        },
      ),
    );
    final saved = await downloadAnalyticsExportFile(
      file,
      dialogTitle: l10n.reportExportCsvAction,
    );
    return switch (saved.status) {
      AnalyticsExportSaveStatus.saved => l10n.reportCsvSavedMessage(
        saved.location ?? file.filename,
      ),
      AnalyticsExportSaveStatus.canceled => l10n.reportCsvCanceledMessage,
      AnalyticsExportSaveStatus.failed => l10n.reportGenerationError,
    };
  }

  /// Builds the printable document from a run that has already been produced.
  ///
  /// The run is passed in rather than rebuilt: preview, print and share used to
  /// each create their own server-side run, so three clicks on one report cost
  /// three aggregations and left three rows in the table.
  Future<BusinessReportPdfDocument?> buildReportDocument(
    BuildContext context,
    ReportRun run,
  ) async {
    final stopwatch = Stopwatch()..start();
    unawaited(
      dependencies.analyticsEngine.trackPerformance(
        name: analyticsEventNameToJson(AnalyticsEventName.frontendOperation),
        duration: stopwatch.elapsed,
        attributes: {
          ..._reportAttributes(run),
          'operation': 'report.build_pdf',
          'report_run_id': run.id,
        },
        metrics: {'row_count': run.rowCount},
      ),
    );
    final shopSettings = await _loadShopSettingsForReport();
    final shopLogoBytes = await _loadShopLogoBytes(shopSettings);
    if (!context.mounted) {
      return null;
    }
    return buildBusinessReportPdfDocument(
      run: run,
      l10n: AppLocalizations.of(context)!,
      currentUser: currentUser,
      includeAuditTrail: true,
      includePreparedBy: true,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
    );
  }

  Future<ShopSettings?> _loadShopSettingsForReport() async {
    final result = await dependencies.shopSettingsRepository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final attachment = settings?.logoAttachment;
    final logoUrl = attachment?.contentUrl.trim();
    final contentType = attachment?.contentType.toLowerCase() ?? '';
    if (logoUrl == null ||
        logoUrl.isEmpty ||
        !_reportPdfLogoContentTypes.contains(contentType)) {
      return null;
    }

    final logoUri = _resolveApiUri(logoUrl);
    if (logoUri == null) {
      return null;
    }

    try {
      final response = await http.get(logoUri);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.bodyBytes;
      }
    } on Exception {
      return null;
    }
    return null;
  }

  Uri? _resolveApiUri(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return null;
    }
    if (uri.hasScheme) {
      return uri;
    }

    final baseUri = Uri.tryParse(dependencies.service.baseUrl);
    if (baseUri == null) {
      return null;
    }
    final directoryBase = baseUri.path.endsWith('/')
        ? baseUri
        : baseUri.replace(path: '${baseUri.path}/');
    return directoryBase.resolveUri(uri);
  }

  Map<String, Object?> _reportAttributes(ReportRun run) {
    final period = run.payload['period'];
    final window = period is Map ? period.cast<String, Object?>() : const {};
    return {
      'report_type': reportRunTypeToJson(run.reportType),
      'granularity': '${window['granularity'] ?? ''}',
      'preset': '${window['preset'] ?? ''}',
      'start_date': '${window['start_date'] ?? ''}',
      'end_date': '${window['end_date'] ?? ''}',
      'source': 'reports_screen',
    };
  }

  void _showReportMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Command palette
  // ---------------------------------------------------------------------------

  /// The sources the global command palette searches: quick actions and
  /// recently opened items, instant screen navigation, plus debounced,
  /// capability-gated entity search that opens the matching detail screen.
  List<CommandSource> buildCommandSources(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showStock = capabilities.canViewStock;
    final canReorder = capabilities.canCreatePurchaseOrder;
    return [
      _quickActionsSource(l10n),
      RecentsCommandSource(
        label: l10n.commandPaletteRecentsSection,
        onOpen: _openRecent,
      ),
      NavigationCommandSource(this),
      if (capabilities.canViewCatalogManagement)
        AsyncCommandSource<Product>(
          labelBuilder: (sectionL10n) =>
              sectionL10n.commandPaletteProductsSection,
          fetch: _searchProducts,
          toItem: (product) {
            final price = formatMoney(product.effectiveUnitPrice);
            return CommandItem(
              id: 'product-${product.id}',
              icon: Icons.inventory_2_outlined,
              title: product.name,
              subtitle: _productSubtitle(l10n, product, showStock: showStock),
              trailing: price,
              recent: RecentEntry(
                kind: RecentKind.product,
                id: product.id,
                title: product.name,
                subtitle: _productRecentSubtitle(product),
                trailing: price,
              ),
              actions: [
                CommandRowAction(
                  icon: Icons.print_outlined,
                  tooltip: l10n.commandPalettePrintLabelAction,
                  onRun: (ctx) => _printProductLabel(ctx, product),
                ),
                if (canReorder)
                  CommandRowAction(
                    icon: Icons.add_shopping_cart_outlined,
                    tooltip: l10n.commandPaletteReorderAction,
                    onRun: (ctx) => _reorderProduct(ctx, product),
                  ),
              ],
              onSelect: (ctx) => _openProduct(ctx, product),
            );
          },
        ),
      if (capabilities.canManageContacts) ...[
        AsyncCommandSource<Customer>(
          labelBuilder: (sectionL10n) =>
              sectionL10n.commandPaletteCustomersSection,
          fetch: _searchCustomers,
          toItem: (customer) {
            final subtitle = [
              if (customer.phone.trim().isNotEmpty) customer.phone.trim(),
              if (customer.customerNumber.trim().isNotEmpty)
                customer.customerNumber.trim(),
            ].join(' · ');
            return CommandItem(
              id: 'customer-${customer.id}',
              icon: Icons.person_outline,
              title: customer.fullName,
              subtitle: subtitle,
              recent: RecentEntry(
                kind: RecentKind.customer,
                id: customer.id,
                title: customer.fullName,
                subtitle: subtitle,
              ),
              onSelect: (ctx) => _openCustomer(ctx, customer),
            );
          },
        ),
        AsyncCommandSource<SupplierContact>(
          labelBuilder: (sectionL10n) =>
              sectionL10n.commandPaletteSuppliersSection,
          fetch: _searchSuppliers,
          toItem: (supplier) {
            final subtitle = [
              if (supplier.contactName.trim().isNotEmpty)
                supplier.contactName.trim(),
              if (supplier.phone.trim().isNotEmpty) supplier.phone.trim(),
            ].join(' · ');
            return CommandItem(
              id: 'supplier-${supplier.id}',
              icon: Icons.local_shipping_outlined,
              title: supplier.name,
              subtitle: subtitle,
              recent: RecentEntry(
                kind: RecentKind.supplier,
                id: supplier.id,
                title: supplier.name,
                subtitle: subtitle,
              ),
              onSelect: (ctx) => _openSupplier(ctx, supplier),
            );
          },
        ),
      ],
      if (capabilities.canViewInvoices)
        AsyncCommandSource<SaleOrder>(
          labelBuilder: (sectionL10n) =>
              sectionL10n.commandPaletteInvoicesSection,
          fetch: _searchInvoices,
          toItem: (order) {
            final receipt = order.receiptNumber;
            final title = receipt == null || receipt.isEmpty
                ? '#${order.id}'
                : receipt;
            final total = formatMoney(order.total);
            return CommandItem(
              id: 'invoice-${order.id}',
              icon: Icons.request_quote_outlined,
              title: title,
              trailing: total,
              recent: RecentEntry(
                kind: RecentKind.invoice,
                id: order.id,
                title: title,
                trailing: total,
              ),
              actions: [
                CommandRowAction(
                  icon: Icons.print_outlined,
                  tooltip: l10n.commandPaletteReprintAction,
                  onRun: (ctx) => _reprintInvoice(ctx, order),
                ),
              ],
              onSelect: (ctx) => _openInvoice(ctx, order),
            );
          },
        ),
      if (capabilities.canAccessPurchasing)
        AsyncCommandSource<PurchaseOrder>(
          labelBuilder: (sectionL10n) =>
              sectionL10n.commandPalettePurchaseOrdersSection,
          fetch: _searchPurchaseOrders,
          toItem: (order) {
            final title = order.orderNumber.isEmpty
                ? '#${order.id}'
                : order.orderNumber;
            final total = formatMoney(order.total);
            return CommandItem(
              id: 'po-${order.id}',
              icon: Icons.add_shopping_cart_outlined,
              title: title,
              trailing: total,
              recent: RecentEntry(
                kind: RecentKind.purchaseOrder,
                id: order.id,
                title: title,
                trailing: total,
              ),
              onSelect: (ctx) => _openPurchaseOrder(ctx, order),
            );
          },
        ),
    ];
  }

  /// Quick actions — verbs that jump straight into a creation flow.
  StaticCommandSource _quickActionsSource(AppLocalizations l10n) {
    return StaticCommandSource(
      label: l10n.commandPaletteActionsSection,
      items: [
        if (capabilities.canAccessPos)
          CommandItem(
            id: 'action-new-sale',
            icon: Icons.point_of_sale_outlined,
            title: l10n.commandPaletteActionNewSale,
            keywords: const ['sale', 'pos', 'بيع'],
            onSelect: (ctx) => navigateTo(ctx, AppNavigationDestination.pos),
          ),
        if (capabilities.canCreatePurchaseOrder)
          CommandItem(
            id: 'action-new-purchase-order',
            icon: Icons.add_shopping_cart_outlined,
            title: l10n.commandPaletteActionNewPurchaseOrder,
            keywords: const ['purchase', 'po', 'شراء'],
            onSelect: _openNewPurchaseOrder,
          ),
        if (capabilities.canManageExpenses)
          CommandItem(
            id: 'action-record-expense',
            icon: Icons.payments_outlined,
            title: l10n.commandPaletteActionRecordExpense,
            keywords: const ['expense', 'مصروف'],
            onSelect: (ctx) =>
                navigateTo(ctx, AppNavigationDestination.expenses),
          ),
        if (capabilities.canCountStock)
          CommandItem(
            id: 'action-stock-count',
            icon: Icons.fact_check_outlined,
            title: l10n.commandPaletteActionStockCount,
            keywords: const ['stock count', 'جرد'],
            onSelect: (ctx) =>
                navigateTo(ctx, AppNavigationDestination.stockCount),
          ),
        CommandItem(
          id: 'action-toggle-theme',
          icon: Icons.brightness_6_outlined,
          title: l10n.appearanceToggleTooltip,
          keywords: const [
            'theme',
            'dark',
            'light',
            'mode',
            'مظهر',
            'داكن',
            'فاتح',
            'وضع',
          ],
          onSelect: (_) => dependencies.themeController.toggleLightDark(),
        ),
      ],
    );
  }

  String _productSubtitle(
    AppLocalizations l10n,
    Product product, {
    required bool showStock,
  }) {
    return [
      if (showStock)
        l10n.commandPaletteStockLabel(
          _formatStock(product.effectiveQuantityOnHand),
        ),
      if (product.effectiveBarcode.isNotEmpty)
        product.effectiveBarcode
      else if (product.effectiveSku.isNotEmpty)
        product.effectiveSku,
    ].join(' · ');
  }

  String _formatStock(double quantity) {
    if (quantity == quantity.roundToDouble()) {
      return quantity.toInt().toString();
    }
    return quantity.toStringAsFixed(2);
  }

  void _openNewPurchaseOrder(BuildContext context) {
    dependencies.purchaseViewModel.clearDraft(trackLineDeletes: false);
    push(context, createPurchaseOrderRouteBuilder);
  }

  String _productRecentSubtitle(Product product) {
    if (product.effectiveBarcode.isNotEmpty) {
      return product.effectiveBarcode;
    }
    return product.effectiveSku;
  }

  Future<void> _printProductLabel(BuildContext context, Product product) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    // The palette prints in one tap, so it takes the counter's remembered
    // answer to "price on the label?" rather than assuming one.
    final includePrice = await barcodeLabelPrintPreferences.includePrice();
    final result = await dependencies.printingRepository.printBarcodeLabels([
      BarcodeLabelPrintLine(
        label: BarcodeLabelDraft.fromProduct(product),
        copies: 1,
        includePrice: includePrice,
      ),
    ]);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? l10n.commandPaletteLabelPrinted
              : l10n.commandPaletteLabelPrintFailed,
        ),
      ),
    );
  }

  Future<void> _reorderProduct(BuildContext context, Product product) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final variant = product.defaultVariant;
    if (variant == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.commandPaletteReorderNoVariant)),
      );
      return;
    }
    dependencies.purchaseViewModel.clearDraft(trackLineDeletes: false);
    await dependencies.purchaseViewModel.addVariant(
      variant,
      source: 'command_palette_reorder',
    );
    if (!context.mounted) {
      return;
    }
    push(context, createPurchaseOrderRouteBuilder);
  }

  Future<void> _reprintInvoice(BuildContext context, SaleOrder order) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final shopSettings = await _loadShopSettingsForReport();
    final logoBytes = await _loadShopLogoBytes(shopSettings);
    final result = await dependencies.printingRepository.printSaleInvoice(
      order: order,
      shopSettings: shopSettings,
      shopLogoBytes: logoBytes,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? l10n.commandPaletteInvoicePrinted
              : l10n.commandPaletteInvoicePrintFailed,
        ),
      ),
    );
  }

  void _openRecent(BuildContext context, RecentEntry entry) {
    switch (entry.kind) {
      case RecentKind.product:
        unawaited(
          _openRecentEntity<Product>(
            context,
            () => dependencies.catalogRepository.loadProduct(entry.id),
            _openProduct,
          ),
        );
      case RecentKind.customer:
        unawaited(
          _openRecentEntity<Customer>(
            context,
            () => dependencies.contactRepository.loadCustomer(entry.id),
            _openCustomer,
          ),
        );
      case RecentKind.supplier:
        unawaited(
          _openRecentEntity<SupplierContact>(
            context,
            () => dependencies.contactRepository.loadSupplier(entry.id),
            _openSupplier,
          ),
        );
      case RecentKind.invoice:
        unawaited(
          _openRecentEntity<SaleOrder>(
            context,
            () => dependencies.saleRepository.loadOrder(entry.id),
            _openInvoice,
          ),
        );
      case RecentKind.purchaseOrder:
        unawaited(
          _openRecentEntity<PurchaseOrder>(
            context,
            () => dependencies.purchaseRepository.loadPurchaseOrder(entry.id),
            _openPurchaseOrder,
          ),
        );
    }
  }

  Future<void> _openRecentEntity<T>(
    BuildContext context,
    Future<Result<T>> Function() fetch,
    void Function(BuildContext context, T value) open,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final result = await fetch();
    if (!context.mounted) {
      return;
    }
    switch (result) {
      case Ok<T>():
        open(context, result.value);
      case Error<T>():
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.commandPaletteOpenError)),
        );
    }
  }

  Future<List<Product>> _searchProducts(String query) async {
    final result = await dependencies.catalogRepository.loadProducts(
      query: ProductQuery(search: query),
    );
    return switch (result) {
      Ok<ProductPage>() => result.value.products,
      Error<ProductPage>() => const [],
    };
  }

  Future<List<Customer>> _searchCustomers(String query) async {
    final result = await dependencies.contactRepository.loadCustomers(
      query: ContactQuery(search: query),
    );
    return switch (result) {
      Ok<CustomerPage>() => result.value.customers,
      Error<CustomerPage>() => const [],
    };
  }

  Future<List<SupplierContact>> _searchSuppliers(String query) async {
    final result = await dependencies.contactRepository.loadSuppliers(
      query: ContactQuery(search: query),
    );
    return switch (result) {
      Ok<SupplierPage>() => result.value.suppliers,
      Error<SupplierPage>() => const [],
    };
  }

  Future<List<SaleOrder>> _searchInvoices(String query) async {
    final result = await dependencies.saleRepository.loadOrders(
      query: SaleOrderQuery(search: query),
    );
    return switch (result) {
      Ok<SaleOrderPage>() => result.value.orders,
      Error<SaleOrderPage>() => const [],
    };
  }

  Future<List<PurchaseOrder>> _searchPurchaseOrders(String query) async {
    final result = await dependencies.purchaseRepository.loadPurchaseOrders(
      query: PurchaseOrderQuery(search: query),
    );
    return switch (result) {
      Ok<PurchaseOrderPage>() => result.value.orders,
      Error<PurchaseOrderPage>() => const [],
    };
  }

  void _openProduct(BuildContext context, Product product) {
    push(
      context,
      (_) => _screen(
        'product_variant_details',
        ProductVariantDetailsScreen(
          viewModel: ProductStockViewModel(
            dependencies.inventoryRepository,
            dependencies.purchaseRepository,
            product,
            analyticsEngine: dependencies.analyticsEngine,
          ),
          printingRepository: dependencies.printingRepository,
          capabilities: capabilities,
          analyticsEngine: dependencies.analyticsEngine,
        ),
      ),
    );
  }

  void _openCustomer(BuildContext context, Customer customer) {
    push(
      context,
      (_) => _screen(
        'customer_details',
        CustomerDetailsScreen(
          customer: customer,
          contactRepository: dependencies.contactRepository,
          printingRepository: dependencies.printingRepository,
          shopSettingsRepository: dependencies.shopSettingsRepository,
        ),
      ),
    );
  }

  void _openSupplier(BuildContext context, SupplierContact supplier) {
    push(
      context,
      (_) => _screen(
        'supplier_details',
        SupplierDetailsScreen(
          supplier: supplier,
          contactRepository: dependencies.contactRepository,
          purchaseRepository: dependencies.purchaseRepository,
          printingRepository: dependencies.printingRepository,
          shopSettingsRepository: dependencies.shopSettingsRepository,
          capabilities: capabilities,
        ),
      ),
    );
  }

  void _openInvoice(BuildContext context, SaleOrder order) {
    push(
      context,
      (_) => _screen(
        'invoice_details',
        InvoiceDetailsScreen(
          saleRepository: dependencies.saleRepository,
          printingRepository: dependencies.printingRepository,
          shopSettingsRepository: dependencies.shopSettingsRepository,
          catalogRepository: dependencies.catalogRepository,
          contactRepository: dependencies.contactRepository,
          initialOrder: order,
          capabilities: capabilities,
          analyticsEngine: dependencies.analyticsEngine,
        ),
      ),
    );
  }

  void _openPurchaseOrder(BuildContext context, PurchaseOrder order) {
    push(
      context,
      (_) => _screen(
        'purchase_order_details',
        PurchaseOrderDetailsScreen(
          purchaseRepository: dependencies.purchaseRepository,
          printingRepository: dependencies.printingRepository,
          shopSettingsRepository: dependencies.shopSettingsRepository,
          initialOrder: order,
          capabilities: capabilities,
          onEditDraft: capabilities.canEditDraftPurchaseOrder
              ? (draft) => openPurchaseOrderEditor(context, draft.id)
              : null,
        ),
      ),
    );
  }

  void _openJobById(BuildContext context, int jobId) {
    push(
      context,
      (_) => _screen(
        'job_details',
        JobDetailsScreen(
          viewModel: JobDetailsViewModel(
            dependencies.operationsRepository,
            jobId: jobId,
            analyticsEngine: dependencies.analyticsEngine,
          ),
          capabilities: capabilities,
          currentUser: currentUser,
          catalogRepository: dependencies.catalogRepository,
          operationsRepository: dependencies.operationsRepository,
          employeeRepository: dependencies.employeeRepository,
        ),
      ),
    );
  }

  /// Open a deep link the AI assistant emitted. Passed to [AiAssistantScreen]
  /// as a callback (not on AppNavigation, to keep the interface lean). Returns
  /// false when the target is unknown, gated by capability, or fails to load.
  Future<bool> openAiLink(BuildContext context, AiDeepLink link) async {
    switch (link) {
      case AiScreenLink(:final key):
        final destination = _destinationForKey(key);
        if (destination == null || !isDestinationAvailable(destination)) {
          return false;
        }
        navigateTo(
          context,
          destination,
          from: AppNavigationDestination.aiAssistant,
        );
        return true;
      case AiEntityLink(:final type, :final id):
        return _openEntityDeepLink(context, type, id);
      case AiChatLink(:final prompt, :final autoSend):
        if (!isDestinationAvailable(AppNavigationDestination.aiAssistant)) {
          return false;
        }
        openAiChat(context, seedPrompt: prompt, autoSend: autoSend);
        return true;
    }
  }

  AppNavigationDestination? _destinationForKey(String key) {
    for (final destination in AppNavigationDestination.values) {
      if (destination.name.toLowerCase() == key) {
        return destination;
      }
    }
    return null;
  }

  Future<bool> _openEntityDeepLink(BuildContext context, String type, int id) {
    switch (type) {
      case 'product':
        return _loadThenOpen(
          context,
          AppCapability.viewCatalogManagement,
          () => dependencies.catalogRepository.loadProduct(id),
          _openProduct,
        );
      case 'customer':
        return _loadThenOpen(
          context,
          AppCapability.manageContacts,
          () => dependencies.contactRepository.loadCustomer(id),
          _openCustomer,
        );
      case 'supplier':
        return _loadThenOpen(
          context,
          AppCapability.manageContacts,
          () => dependencies.contactRepository.loadSupplier(id),
          _openSupplier,
        );
      case 'order' || 'sale' || 'invoice':
        return _loadThenOpen(
          context,
          AppCapability.viewInvoices,
          () => dependencies.saleRepository.loadOrder(id),
          _openInvoice,
        );
      case 'purchase-order' || 'purchase' || 'po':
        return _loadThenOpen(
          context,
          AppCapability.accessPurchasing,
          () => dependencies.purchaseRepository.loadPurchaseOrder(id),
          _openPurchaseOrder,
        );
      case 'job':
        if (!capabilities.allows(AppCapability.viewOperations)) {
          return Future.value(false);
        }
        _openJobById(context, id);
        return Future.value(true);
      default:
        return Future.value(false);
    }
  }

  /// Capability-gate, load the record by id, then push its detail screen —
  /// reusing the same `_openX` push helpers the list screens use. Returns false
  /// (so the caller can message the user) when blocked or the load fails.
  Future<bool> _loadThenOpen<T>(
    BuildContext context,
    AppCapability capability,
    Future<Result<T>> Function() load,
    void Function(BuildContext, T) open,
  ) async {
    if (!capabilities.allows(capability)) {
      return false;
    }
    final result = await load();
    if (!context.mounted) {
      return false;
    }
    switch (result) {
      case Ok(value: final entity):
        open(context, entity);
        return true;
      case Error():
        return false;
    }
  }
}

const _reportPdfLogoContentTypes = {'image/jpeg', 'image/jpg', 'image/png'};
