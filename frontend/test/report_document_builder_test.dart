import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/report_run.dart';
import 'package:pointy_frontend/src/features/reports/pdf/report_document_builder.dart';

void main() {
  testWidgets('report tables carry no raw English keys or values', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final run = ReportRun(
      id: 1,
      reportType: ReportRunType.profitCosts,
      params: const {},
      outputFormat: ReportOutputFormat.pdf,
      status: ReportRunStatus.success,
      payload: const {
        'summary': {'gross_profit': '5.00'},
        'sections': [
          {
            'key': 'summary',
            'columns': ['metric', 'value'],
            'rows': [
              {'metric': 'gross_profit', 'value': '5.00'},
              {'metric': 'net_operating_profit', 'value': '5.00'},
            ],
          },
          {
            'key': 'cost_breakdown',
            'columns': ['cost_item', 'amount'],
            'rows': [
              {'cost_item': 'payroll_paid_total', 'amount': '200.00'},
            ],
          },
        ],
        'period': {'start_date': '2026-06-01', 'end_date': '2026-06-12'},
      },
      rowCount: 3,
      checksum: 'abcdef0123456789',
      createdAt: DateTime(2026, 6, 12),
    );

    final document = buildBusinessReportPdfDocument(
      run: run,
      l10n: l10n,
      currentUser: PosUser.fromJson(const {
        'id': 1,
        'username': 'manager',
        'display_name': 'مدير',
        'email': '',
        'role': 'manager',
        'permissions': <String>[],
        'is_active': true,
      }),
      includeAuditTrail: false,
      includePreparedBy: false,
    );

    final englishWord = RegExp(r'[a-z]+_[a-z]+');
    for (final section in document.sections) {
      for (final table in section.tables) {
        for (final column in table.columns) {
          expect(englishWord.hasMatch(column), isFalse, reason: column);
        }
        for (final row in table.rows) {
          for (final cell in row) {
            expect(englishWord.hasMatch(cell), isFalse, reason: cell);
          }
        }
      }
    }
  });
}
