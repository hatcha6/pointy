import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_export.dart';
import 'package:pointy_frontend/src/data/models/report_catalog.dart';
import 'package:pointy_frontend/src/data/models/report_run.dart';
import 'package:pointy_frontend/src/data/repositories/report_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/reports/view_models/reports_view_model.dart';

/// A reports backend that answers instantly, so a widget test can drive the
/// screen without a server.
///
/// The catalogue it returns is deliberately the real shape: the screen is now
/// driven by what the server says it may run, so a fake that hard-codes tiles
/// would test a screen nobody ships.
class FakeReportRepository extends ReportRepository {
  FakeReportRepository({
    this.createFailure,
    this.lockedThrough,
    this.historyRows = const [],
  }) : super(PosApiService());

  /// When set, `createReportRun` fails with this as the server's own reason.
  final String? createFailure;
  final DateTime? lockedThrough;
  final List<ReportRunSummary> historyRows;

  int createCalls = 0;
  int verifyCalls = 0;
  int csvCalls = 0;
  DateTime? savedLock;
  int savedFiscalYearStartMonth = 1;

  ReportsViewModel viewModel() => ReportsViewModel(this);

  @override
  Future<Result<ReportCatalog>> loadCatalog() async {
    return Ok(
      ReportCatalog.fromJson({
        'reports': [
          {
            'key': 'sales_summary',
            'category': 'sales',
            'headline': ['net_sales', 'gross_profit'],
            'required_params': <String>[],
            'point_in_time': false,
          },
          {
            'key': 'receivables_aging',
            'category': 'receivables',
            'headline': ['receivable_total'],
            'required_params': <String>[],
            'point_in_time': true,
          },
          {
            'key': 'customer_statement',
            'category': 'receivables',
            'headline': ['closing_balance'],
            'required_params': ['customer_id'],
            'point_in_time': false,
          },
        ],
        'presets': [
          'today',
          'week',
          'month',
          'last_month',
          'quarter',
          'year',
          'custom',
        ],
        'granularities': ['summary', 'daily', 'detailed'],
        'comparisons': ['none', 'previous_period', 'previous_year'],
        'fiscal_year_start_month': 1,
        'can_manage_period_lock': true,
        'books_locked_through': lockedThrough?.toIso8601String().substring(
          0,
          10,
        ),
      }),
    );
  }

  @override
  Future<Result<ReportRun>> createReportRun(ReportRunDraft draft) async {
    createCalls++;
    final failure = createFailure;
    if (failure != null) {
      return Error(Exception('{"detail": "$failure"}'));
    }
    return Ok(
      ReportRun(
        id: createCalls,
        reportType: draft.reportType,
        params: draft.params,
        outputFormat: draft.outputFormat,
        status: ReportRunStatus.success,
        payload: _payload(),
        rowCount: 1,
        checksum: 'run-checksum',
        figuresChecksum: 'figures-checksum',
        createdAt: DateTime(2026, 9, 1),
      ),
    );
  }

  @override
  Future<Result<List<ReportRunSummary>>> loadHistory({
    ReportRunType? type,
    int limit = 25,
  }) async {
    return Ok(historyRows);
  }

  @override
  Future<Result<ReportVerification>> verifyRun(int id) async {
    verifyCalls++;
    return Ok(
      ReportVerification.fromJson({
        'run_id': id,
        'matches': true,
        'changed_figures': <String>[],
        'stored_summary': <String, Object?>{},
        'current_summary': <String, Object?>{},
      }),
    );
  }

  @override
  Future<Result<AnalyticsExportFile>> downloadCsv(ReportRunDraft draft) async {
    csvCalls++;
    return Error(Exception('not exercised in widget tests'));
  }

  @override
  Future<Result<PeriodLockState>> setPeriodLock({
    DateTime? lockedThrough,
    bool includeLockedThrough = true,
    int? fiscalYearStartMonth,
    String note = '',
    bool acknowledged = false,
  }) async {
    if (includeLockedThrough) {
      savedLock = lockedThrough;
    }
    savedFiscalYearStartMonth =
        fiscalYearStartMonth ?? savedFiscalYearStartMonth;
    return Ok(
      PeriodLockState(
        lockedThrough: savedLock,
        fiscalYearStartMonth: savedFiscalYearStartMonth,
        canManage: true,
      ),
    );
  }

  Map<String, Object?> _payload() {
    return {
      'report_type': 'sales_summary',
      'headline': ['net_sales', 'gross_profit'],
      'summary': {'net_sales': '120.00', 'gross_profit': '40.00'},
      'period': {
        'start_date': '2026-08-01',
        'end_date': '2026-08-31',
        'preset': 'last_month',
        'granularity': 'summary',
      },
      'sections': [
        {
          'key': 'summary',
          'columns': ['metric', 'value'],
          'column_types': {'metric': 'label', 'value': 'text'},
          'rows': [
            {'metric': 'net_sales', 'value': '120.00'},
          ],
          'metadata': {
            'returned_count': 1,
            'total_count': 1,
            'omitted_count': 0,
            'truncated': false,
          },
        },
        {
          'key': 'top_products',
          'columns': ['product_name', 'revenue'],
          'column_types': {'product_name': 'text', 'revenue': 'money'},
          'rows': [
            {'product_name': 'قهوة', 'revenue': '120.00'},
          ],
          'metadata': {
            'returned_count': 1,
            'total_count': 3,
            'omitted_count': 2,
            'truncated': true,
          },
          'totals': {
            'shown': {'revenue': '120.00'},
            'full': {'revenue': '300.00'},
          },
        },
      ],
      'notes': [
        {'code': 'basis_accrual_sales'},
        {'code': 'period_open'},
      ],
      'audit': {'row_count': 2, 'truncated': true, 'omitted_count': 2},
      'generated_at': '2026-09-01T10:00:00Z',
    };
  }
}
