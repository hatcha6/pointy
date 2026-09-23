// Dev-only preview harness for the reports screen.
//
// Renders the real reports screen with a fake repository and no backend/auth.
// The catalogue is the server's real one plus one report a newer server might
// add — which must be left out, not shown as another "sales summary" tile.
// Payloads come from lib/dev/reports_preview_payloads.dart. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/reports_preview.dart
//
// Screens: board | reports | result
// Reports: `?report=` any catalogue key — balance_sheet (default), unit_aging,
//          unit_margin, unit_ledger, consignment_ledger
//
// `?screen=board` lays the screen out at phone and desktop widths side by side
// (size the viewport large — e.g. 1800x2600 — so Flutter paints both frames).
// `reports` is the screen full-viewport with the report selected and run;
// `result` is the report's result alone.
//
// See AGENTS.md ("UI preview harness"). Not part of the shipping app. Safe to
// delete.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/report_catalog.dart';
import 'package:pointy_frontend/src/data/models/report_run.dart';
import 'package:pointy_frontend/src/data/repositories/report_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/reports/view_models/reports_view_model.dart';
import 'package:pointy_frontend/src/features/reports/views/report_result_view.dart';
import 'package:pointy_frontend/src/features/reports/views/reports_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'reports_preview_payloads.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _PreviewRouter(),
    );
  }
}

String? _query(String name) {
  final uri = Uri.base;
  final direct = uri.queryParameters[name];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters[name];
}

String _selectedScreen() => _query('screen') ?? 'reports';

ReportRunType _selectedReport() =>
    reportRunTypeFromKey(_query('report')) ?? ReportRunType.balanceSheet;

class _PreviewRouter extends StatelessWidget {
  const _PreviewRouter();

  @override
  Widget build(BuildContext context) {
    return switch (_selectedScreen()) {
      'board' => const _DesignBoard(),
      'result' => Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ReportResultView(run: _run(_selectedReport(), const {})),
        ),
      ),
      _ => const _ReportsHost(),
    };
  }
}

/// The real screen, with the chosen report selected and already run.
class _ReportsHost extends StatefulWidget {
  const _ReportsHost();

  @override
  State<_ReportsHost> createState() => _ReportsHostState();
}

class _ReportsHostState extends State<_ReportsHost> {
  final _viewModel = ReportsViewModel(_FakeReportRepository());

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    await _viewModel.load();
    final report = _selectedReport();
    _viewModel
      ..selectType(report)
      ..selectPreset(
        report == ReportRunType.balanceSheet
            ? ReportPeriodPresetOption.year
            : ReportPeriodPresetOption.month,
      )
      ..selectUnitCode(previewUnitCode);
    await _viewModel.runReport();
  }

  @override
  Widget build(BuildContext context) {
    final navigation = _FakeNavigation();
    return ReportsScreen(
      capabilities: navigation.capabilities,
      navigation: navigation,
      viewModel: _viewModel,
    );
  }
}

class _DesignBoard extends StatelessWidget {
  const _DesignBoard();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9E6DF),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: const [
            _Frame(width: 390, height: 2400),
            _Frame(width: 1280, height: 2400),
          ],
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final size = Size(width, height);
    return SizedBox(
      width: width,
      height: height,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: size,
          padding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        child: const _ReportsHost(),
      ),
    );
  }
}

class _FakeReportRepository extends ReportRepository {
  _FakeReportRepository() : super(PosApiService());

  var _runs = 0;

  @override
  Future<Result<ReportCatalog>> loadCatalog() async {
    return Ok(
      ReportCatalog.fromJson({
        'reports': _serverCatalog,
        'presets': const [
          'today',
          'yesterday',
          'week',
          'month',
          'last_month',
          'quarter',
          'last_quarter',
          'year',
          'last_year',
          'custom',
        ],
        'granularities': const ['summary', 'daily', 'detailed'],
        'comparisons': const ['none', 'previous_period', 'previous_year'],
        'fiscal_year_start_month': 1,
        'can_manage_period_lock': true,
      }),
    );
  }

  @override
  Future<Result<ReportRun>> createReportRun(ReportRunDraft draft) async {
    _runs++;
    return Ok(_run(draft.reportType, draft.params, id: _runs));
  }

  @override
  Future<Result<List<ReportRunSummary>>> loadHistory({
    ReportRunType? type,
    int limit = 25,
  }) async {
    return const Ok([]);
  }
}

/// Every report the server offers today, in its own order, and one it might
/// add tomorrow.
const _serverCatalog = [
  {'key': 'sales_summary', 'category': 'sales'},
  {'key': 'payment_methods', 'category': 'payments'},
  {'key': 'register_closure', 'category': 'cash'},
  {'key': 'inventory_status', 'category': 'inventory', 'point_in_time': true},
  {'key': 'stock_movements', 'category': 'inventory'},
  {'key': 'purchasing_summary', 'category': 'purchasing'},
  {'key': 'reorder_items', 'category': 'inventory', 'point_in_time': true},
  {'key': 'payroll_summary', 'category': 'employees'},
  {'key': 'profit_costs', 'category': 'sales'},
  {
    'key': 'receivables_aging',
    'category': 'receivables',
    'point_in_time': true,
  },
  {'key': 'payables_aging', 'category': 'payables', 'point_in_time': true},
  {
    'key': 'customer_statement',
    'category': 'receivables',
    'required_params': ['customer_id'],
  },
  {
    'key': 'supplier_statement',
    'category': 'payables',
    'required_params': ['supplier_id'],
  },
  {'key': 'cash_position', 'category': 'cash'},
  {'key': 'expense_breakdown', 'category': 'expenses'},
  {'key': 'product_margin', 'category': 'sales'},
  {'key': 'discount_audit', 'category': 'sales'},
  {'key': 'sales_by_staff', 'category': 'sales'},
  {'key': 'month_end_pack', 'category': 'close'},
  {'key': 'balance_sheet', 'category': 'close'},
  {'key': 'unit_aging', 'category': 'inventory', 'point_in_time': true},
  {'key': 'unit_margin', 'category': 'inventory'},
  {
    'key': 'unit_ledger',
    'category': 'inventory',
    'required_params': ['code'],
    'point_in_time': true,
  },
  {'key': 'consignment_ledger', 'category': 'inventory'},
  {'key': 'fixed_asset_register', 'category': 'assets'},
];

ReportRun _run(ReportRunType type, Map<String, Object?> params, {int id = 1}) {
  return ReportRun(
    id: id,
    reportType: type,
    params: params,
    outputFormat: ReportOutputFormat.pdf,
    status: ReportRunStatus.success,
    payload: previewPayload(type),
    rowCount: 26,
    checksum: 'preview',
    figuresChecksum: 'preview',
    createdAt: DateTime(2026, 9, 23),
  );
}

class _FakeNavigation implements AppNavigation {
  @override
  PosUser get currentUser => const PosUser(
    id: 1,
    username: 'manager',
    role: UserRole.manager,
    isActive: true,
  );

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(currentUser);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}
