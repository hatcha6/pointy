import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/report_run.dart';
import 'package:pointy_frontend/src/features/reports/views/report_result_view.dart';

/// The on-screen report has to say the three things the printed one used to
/// leave out: that a schedule is short, what it totals, and what its figures
/// mean.
void main() {
  Future<void> pump(WidgetTester tester, Map<String, Object?> payload) async {
    tester.view
      ..physicalSize = const Size(1200, 1400)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReportResultView(run: _run(payload)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says how many rows a short schedule left out', (tester) async {
    await pump(tester, _payload());
    expect(find.textContaining('معروض 1 من 3'), findsOneWidget);
  });

  testWidgets('prints both totals when rows were omitted', (tester) async {
    await pump(tester, _payload());
    // What the printed rows add up to, and what every row adds up to — the
    // only honest way to foot a truncated schedule.
    expect(find.text('إجمالي المعروض'), findsOneWidget);
    expect(find.text('إجمالي كل الصفوف'), findsOneWidget);
    expect(find.text('300.00 د.ل'), findsOneWidget);
  });

  testWidgets('prints only one total when nothing was omitted', (tester) async {
    final payload = _payload();
    final section = (payload['sections'] as List)[1] as Map<String, Object?>;
    section['metadata'] = {
      'returned_count': 1,
      'total_count': 1,
      'omitted_count': 0,
      'truncated': false,
    };
    section['totals'] = {
      'shown': {'revenue': '120.00'},
      'full': {'revenue': '120.00'},
    };
    await pump(tester, payload);

    expect(find.text('إجمالي كل الصفوف'), findsNothing);
    expect(find.textContaining('معروض 1 من'), findsNothing);
  });

  testWidgets('translates a metric name held as a row value', (tester) async {
    await pump(tester, _payload());
    // The summary table holds payload keys as cell values; an untranslated one
    // prints `net_sales` at a customer.
    expect(find.text('net_sales'), findsNothing);
    expect(find.text('صافي المبيعات'), findsWidgets);
  });

  testWidgets('carries the definitions that explain the figures', (
    tester,
  ) async {
    await pump(tester, _payload());
    expect(find.text('تعريفات وملاحظات'), findsOneWidget);
    expect(find.textContaining('الفواتير الآجلة'), findsOneWidget);
  });

  testWidgets('says whether the period can still change', (tester) async {
    await pump(tester, _payload());
    expect(find.text('فترة مفتوحة'), findsOneWidget);

    final closed = _payload();
    closed['notes'] = [
      {
        'code': 'period_closed',
        'args': {'date': '2026-08-31'},
      },
    ];
    await pump(tester, closed);
    expect(find.text('فترة مقفلة'), findsOneWidget);
  });

  testWidgets('shows the movement against the comparison window', (
    tester,
  ) async {
    final payload = _payload();
    payload['previous_summary'] = {'net_sales': '100.00'};
    await pump(tester, payload);

    expect(find.textContaining('+20.0%'), findsOneWidget);
  });
}

ReportRun _run(Map<String, Object?> payload) {
  return ReportRun(
    id: 1,
    reportType: ReportRunType.salesSummary,
    params: const {},
    outputFormat: ReportOutputFormat.pdf,
    status: ReportRunStatus.success,
    payload: payload,
    rowCount: 2,
    checksum: 'run',
    figuresChecksum: 'figures',
    createdAt: DateTime(2026, 9, 1),
  );
}

Map<String, Object?> _payload() {
  return <String, Object?>{
    'report_type': 'sales_summary',
    'headline': ['net_sales'],
    'summary': {'net_sales': '120.00'},
    'period': {'start_date': '2026-08-01', 'end_date': '2026-08-31'},
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
