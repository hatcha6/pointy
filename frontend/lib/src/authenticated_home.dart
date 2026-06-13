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
import 'data/models/report_run.dart';
import 'data/models/sale_order.dart';
import 'data/models/shop_settings.dart';
import 'features/activity_log/views/activity_log_event_presenter.dart';
import 'features/activity_log/views/activity_log_screen.dart';
import 'features/catalog/view_models/catalog_view_model.dart';
import 'features/catalog/view_models/category_management_view_model.dart';
import 'features/catalog/views/category_management_screen.dart';
import 'features/catalog/views/catalog_screen.dart';
import 'features/contacts/views/contact_management_screen.dart';
import 'features/dashboard/views/dashboard_screen.dart';
import 'features/fraud/view_models/integrity_monitor_view_model.dart';
import 'features/fraud/views/integrity_monitor_screen.dart';
import 'features/device_settings/views/device_settings_screen.dart';
import 'features/discounts/views/discount_management_screen.dart';
import 'features/employees/views/employee_payroll_screen.dart';
import 'features/invoices/views/invoice_details_screen.dart';
import 'features/invoices/views/invoice_list_screen.dart';
import 'features/notifications/views/notification_center_host.dart';
import 'features/operations/view_models/job_details_view_model.dart';
import 'features/operations/view_models/jobs_board_view_model.dart';
import 'features/operations/view_models/recipes_view_model.dart';
import 'features/operations/view_models/workflows_view_model.dart';
import 'features/operations/views/job_details_screen.dart';
import 'features/operations/views/jobs_screen.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';
import 'features/purchasing/views/purchase_order_details_screen.dart';
import 'features/purchasing/views/purchase_order_list_screen.dart';
import 'features/purchasing/views/purchasing_screen.dart';
import 'features/register_sessions/view_models/register_session_history_view_model.dart';
import 'features/register_sessions/views/register_session_history_screen.dart';
import 'features/reports/pdf/report_document_builder.dart';
import 'features/reports/pdf/report_pdf.dart';
import 'features/reports/views/report_pdf_preview_screen.dart';
import 'features/reports/views/reports_screen.dart';
import 'features/settings/view_models/sales_channels_view_model.dart';
import 'features/settings/view_models/shop_settings_view_model.dart';
import 'features/settings/views/shop_settings_screen.dart';
import 'features/user_settings/views/user_settings_screen.dart';
import 'features/users/view_models/user_management_view_model.dart';
import 'features/users/view_models/user_details_view_model.dart';
import 'features/users/views/user_details_screen.dart';
import 'features/users/views/user_management_screen.dart';
import 'shared/navigation/app_navigation.dart';

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
    return NotificationCenterHost(
      viewModel: dependencies.notificationCenterViewModel,
      onOpenAlert: routes.openBusinessAlert,
      child: home,
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
  void logout(BuildContext context) {
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
  }) {
    final builder = _destinationRouteBuilder(destination);
    if (from == AppNavigationDestination.pos) {
      unawaited(_pushFromPos(context, destination, builder));
      return;
    }
    if (ModalRoute.of(context)?.isFirst ?? false) {
      push(context, builder);
      return;
    }
    replace(context, builder);
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

  WidgetBuilder _destinationRouteBuilder(
    AppNavigationDestination destination,
  ) {
    return switch (destination) {
      AppNavigationDestination.userSettings => userSettingsRouteBuilder,
      AppNavigationDestination.operations => operationsRouteBuilder,
      AppNavigationDestination.invoices => invoicesRouteBuilder,
      AppNavigationDestination.purchasing => purchasingRouteBuilder,
      AppNavigationDestination.contacts => contactsRouteBuilder,
      AppNavigationDestination.catalog => catalogRouteBuilder,
      AppNavigationDestination.categories => categoryRouteBuilder,
      AppNavigationDestination.registerSessions =>
        registerSessionsRouteBuilder,
      AppNavigationDestination.employees => employeePayrollRouteBuilder,
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
        recipesViewModel: RecipesViewModel(
          dependencies.operationsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        onOpenJob: (job) {
          _trackScreenView('job_details');
          push(
            routeContext,
            (_) => JobDetailsScreen(
              viewModel: JobDetailsViewModel(
                dependencies.operationsRepository,
                jobId: job.id,
                analyticsEngine: dependencies.analyticsEngine,
              ),
              capabilities: capabilities,
              currentUser: currentUser,
              catalogRepository: dependencies.catalogRepository,
              operationsRepository: dependencies.operationsRepository,
            ),
          );
        },
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
        ),
        inventoryRepository: dependencies.inventoryRepository,
        printingRepository: dependencies.printingRepository,
        purchaseRepository: dependencies.purchaseRepository,
        saleRepository: dependencies.saleRepository,
        shopSettingsRepository: dependencies.shopSettingsRepository,
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
          _trackScreenView('invoice_details');
          await push(
            routeContext,
            (context) => InvoiceDetailsScreen(
              saleRepository: dependencies.saleRepository,
              printingRepository: dependencies.printingRepository,
              shopSettingsRepository: dependencies.shopSettingsRepository,
              initialOrder: order,
              capabilities: capabilities,
              analyticsEngine: dependencies.analyticsEngine,
            ),
          );
          await dependencies.invoiceListViewModel.loadInvoices();
        }),
        detailPaneBuilder: (context, order) => InvoiceDetailsView(
          saleRepository: dependencies.saleRepository,
          printingRepository: dependencies.printingRepository,
          shopSettingsRepository: dependencies.shopSettingsRepository,
          initialOrder: order,
          capabilities: capabilities,
          analyticsEngine: dependencies.analyticsEngine,
          showHeader: true,
        ),
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
        onOpenUserDetails: guardedValueAction(AppCapability.manageUsers, (
          user,
        ) {
          _trackScreenView('user_details');
          push(
            routeContext,
            (_) => UserDetailsScreen(
              viewModel: UserDetailsViewModel(
                dependencies.userRepository,
                initialUser: user,
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget employeePayrollRouteBuilder(BuildContext routeContext) {
    return _screen(
      'employees',
      EmployeePayrollScreen(
        viewModel: dependencies.employeePayrollViewModel,
        userRepository: dependencies.userRepository,
        capabilities: capabilities,
        navigation: this,
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
        salesChannelsViewModel: SalesChannelsViewModel(
          dependencies.salesChannelRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        workflowsViewModel: WorkflowsViewModel(
          dependencies.operationsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
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
        onPreviewPdf: (request) => previewReport(routeContext, request),
        onPrintReport: (request) => printReport(routeContext, request),
        onExportArchive: (request) => shareReport(routeContext, request),
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

  Widget deviceSettingsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'device_settings',
      DeviceSettingsScreen(
        deviceSettingsViewModel: dependencies.deviceSettingsViewModel,
        printingSettingsViewModel: dependencies.printingSettingsViewModel,
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
            _trackScreenView('purchase_order_details');
            await push(
              routeContext,
              (context) => PurchaseOrderDetailsScreen(
                purchaseRepository: dependencies.purchaseRepository,
                printingRepository: dependencies.printingRepository,
                shopSettingsRepository: dependencies.shopSettingsRepository,
                initialOrder: order,
                capabilities: capabilities,
              ),
            );
            await dependencies.purchaseOrderListViewModel.loadOrders();
          },
        ),
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

  Widget _screen(String screenName, Widget child) {
    _trackScreenView(screenName);
    return child;
  }

  void _trackScreenView(String screenName) {
    dependencies.analyticsEngine.setCurrentScreen(screenName);
    unawaited(
      dependencies.analyticsEngine.trackUsage(
        AnalyticsEventName.frontendScreenViewed,
        attributes: {'screen': screenName, 'role': currentUser.role.toJson()},
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

  Future<void> previewReport(
    BuildContext context,
    ReportRequest request,
  ) async {
    final document = await buildReportDocument(context, request);
    if (document == null || !context.mounted) {
      return;
    }
    unawaited(
      dependencies.analyticsEngine.trackUsage(
        AnalyticsEventName.reportPreviewed,
        attributes: _reportAttributes(request),
      ),
    );
    unawaited(push(context, (_) => ReportPdfPreviewScreen(document: document)));
  }

  Future<void> printReport(BuildContext context, ReportRequest request) async {
    final document = await buildReportDocument(context, request);
    if (document == null || !context.mounted) {
      return;
    }
    final printed = await const ReportPrintingService().print(document);
    if (printed && context.mounted) {
      unawaited(
        dependencies.analyticsEngine.trackUsage(
          AnalyticsEventName.reportPrinted,
          attributes: _reportAttributes(request),
        ),
      );
      _showReportMessage(
        context,
        AppLocalizations.of(context)!.reportPrintQueuedMessage,
      );
    }
  }

  Future<void> shareReport(BuildContext context, ReportRequest request) async {
    final document = await buildReportDocument(context, request);
    if (document == null || !context.mounted) {
      return;
    }
    final shared = await const ReportPrintingService().share(document);
    if (shared && context.mounted) {
      unawaited(
        dependencies.analyticsEngine.trackUsage(
          AnalyticsEventName.reportShared,
          attributes: _reportAttributes(request),
        ),
      );
      _showReportMessage(
        context,
        AppLocalizations.of(context)!.reportArchiveSharedMessage,
      );
    }
  }

  Future<BusinessReportPdfDocument?> buildReportDocument(
    BuildContext context,
    ReportRequest request,
  ) async {
    final stopwatch = Stopwatch()..start();
    final result = await dependencies.reportRepository.createReportRun(
      ReportRunDraft(
        reportType: _reportRunTypeForRequest(request.type),
        outputFormat: ReportOutputFormat.pdf,
        params: {
          "start_date": _apiDate(request.dateRange.start),
          "end_date": _apiDate(request.dateRange.end),
          "granularity": request.granularity.name,
        },
      ),
    );
    if (!context.mounted) {
      return null;
    }

    switch (result) {
      case Ok<ReportRun>(value: final run):
        if (run.status == ReportRunStatus.failed) {
          unawaited(
            dependencies.analyticsEngine.trackUsage(
              AnalyticsEventName.reportGenerationFailed,
              severity: AnalyticsEventSeverity.warning,
              attributes: {
                ..._reportAttributes(request),
                'error_message': run.errorMessage,
              },
              flushImmediately: true,
            ),
          );
          _showReportMessage(
            context,
            run.errorMessage.isEmpty
                ? AppLocalizations.of(context)!.reportGenerationError
                : run.errorMessage,
          );
          return null;
        }
        unawaited(
          dependencies.analyticsEngine.trackPerformance(
            name: analyticsEventNameToJson(
              AnalyticsEventName.frontendOperation,
            ),
            duration: stopwatch.elapsed,
            attributes: {
              ..._reportAttributes(request),
              'operation': 'report.generate_pdf',
              'report_run_id': run.id,
            },
            metrics: {'row_count': run.rowCount},
          ),
        );
        unawaited(
          dependencies.analyticsEngine.trackUsage(
            AnalyticsEventName.reportGenerated,
            attributes: {
              ..._reportAttributes(request),
              'report_run_id': run.id,
              'status': run.status.name,
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
          includeAuditTrail: request.includeAuditTrail,
          includePreparedBy: request.includePreparedBy,
          shopSettings: shopSettings,
          shopLogoBytes: shopLogoBytes,
        );
      case Error<ReportRun>():
        unawaited(
          dependencies.analyticsEngine.trackUsage(
            AnalyticsEventName.reportGenerationFailed,
            severity: AnalyticsEventSeverity.error,
            attributes: _reportAttributes(request),
            flushImmediately: true,
          ),
        );
        _showReportMessage(
          context,
          AppLocalizations.of(context)!.reportGenerationError,
        );
        return null;
    }
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

  Map<String, Object?> _reportAttributes(ReportRequest request) {
    return {
      'report_type': request.type.name,
      'granularity': request.granularity.name,
      'start_date': _apiDate(request.dateRange.start),
      'end_date': _apiDate(request.dateRange.end),
      'include_audit_trail': request.includeAuditTrail,
      'include_prepared_by': request.includePreparedBy,
      'source': 'reports_screen',
    };
  }

  ReportRunType _reportRunTypeForRequest(ReportType type) {
    return switch (type) {
      ReportType.salesSummary => ReportRunType.salesSummary,
      ReportType.registerSessions => ReportRunType.registerClosure,
      ReportType.payments => ReportRunType.paymentMethods,
      ReportType.inventoryValue => ReportRunType.inventoryStatus,
      ReportType.stockMovement => ReportRunType.stockMovements,
      ReportType.purchases => ReportRunType.purchasingSummary,
      ReportType.reorderItems => ReportRunType.reorderItems,
      ReportType.payrollSummary => ReportRunType.payrollSummary,
      ReportType.profitCosts => ReportRunType.profitCosts,
    };
  }

  String _apiDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  void _showReportMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

const _reportPdfLogoContentTypes = {'image/jpeg', 'image/jpg', 'image/png'};
