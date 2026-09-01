import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/report_catalog.dart';
import 'package:pointy_frontend/src/data/models/report_run.dart';

import 'fake_report_repository.dart';

void main() {
  group('the request the screen sends', () {
    test('a preset is sent as a preset, not as two dates', () async {
      // The server resolves it, so the stored run records the days it actually
      // covered. A device with a wrong clock can no longer label an August
      // window as September.
      final viewModel = FakeReportRepository().viewModel();
      viewModel.selectPreset(ReportPeriodPresetOption.lastMonth);

      final params = viewModel.currentParams();
      expect(params['preset'], 'last_month');
      expect(params.containsKey('start_date'), isFalse);
    });

    test('a custom window sends its dates instead', () async {
      final viewModel = FakeReportRepository().viewModel();
      viewModel.selectCustomRange(
        DateTimeRange(start: DateTime(2026, 3, 1), end: DateTime(2026, 3, 31)),
      );

      final params = viewModel.currentParams();
      expect(params['preset'], isNull);
      expect(params['start_date'], '2026-03-01');
      expect(params['end_date'], '2026-03-31');
    });

    test('the detail level and comparison ride along', () {
      final viewModel = FakeReportRepository().viewModel();
      viewModel.selectGranularity(ReportGranularityOption.detailed);
      viewModel.selectComparison(ReportComparisonOption.previousYear);

      final params = viewModel.currentParams();
      expect(params['granularity'], 'detailed');
      expect(params['comparison'], 'previous_year');
    });
  });

  group('building once', () {
    test('an unchanged selection reuses the run it already has', () async {
      final repository = FakeReportRepository();
      final viewModel = repository.viewModel();
      await viewModel.load();

      await viewModel.ensureRun();
      await viewModel.ensureRun();
      await viewModel.ensureRun();

      // Preview, print and share each used to be a separate server-side
      // aggregation and a separate stored run.
      expect(repository.createCalls, 1);
    });

    test('changing the window builds again', () async {
      final repository = FakeReportRepository();
      final viewModel = repository.viewModel();
      await viewModel.load();

      await viewModel.ensureRun();
      viewModel.selectPreset(ReportPeriodPresetOption.year);
      await viewModel.ensureRun();

      expect(repository.createCalls, 2);
    });

    test('a stale result is marked rather than thrown away', () async {
      final viewModel = FakeReportRepository().viewModel();
      await viewModel.load();
      await viewModel.ensureRun();
      expect(viewModel.resultMatchesSelection, isTrue);

      viewModel.selectPreset(ReportPeriodPresetOption.year);
      expect(viewModel.hasResult, isTrue);
      expect(viewModel.resultMatchesSelection, isFalse);
    });
  });

  group('what the user is told when it fails', () {
    test('the server reason survives instead of a generic failure', () async {
      final viewModel = FakeReportRepository(
        createFailure: 'Start date must be before end date.',
      ).viewModel();

      final run = await viewModel.runReport();
      expect(run, isNull);
      expect(viewModel.errorMessage, 'Start date must be before end date.');
    });
  });

  group('a statement needs its party', () {
    test('cannot run until a customer is chosen', () async {
      final viewModel = FakeReportRepository().viewModel();
      await viewModel.load();

      viewModel.selectType(ReportRunType.customerStatement);
      expect(viewModel.canRun, isFalse);

      viewModel.selectCustomer(7, 'زبون');
      expect(viewModel.canRun, isTrue);
      expect(viewModel.currentParams()['customer_id'], 7);
    });

    test('a report that needs nothing can always run', () async {
      final viewModel = FakeReportRepository().viewModel();
      await viewModel.load();
      expect(viewModel.canRun, isTrue);
    });
  });

  group('the catalogue decides what is offered', () {
    test('reports are grouped by the category the server sent', () async {
      final viewModel = FakeReportRepository().viewModel();
      await viewModel.load();

      expect(viewModel.reportsByCategory.keys, containsAll(['sales', 'receivables']));
      expect(viewModel.reportsByCategory['receivables']!.length, 2);
    });

    test('a selection the server does not offer falls back', () async {
      final viewModel = FakeReportRepository().viewModel();
      viewModel.selectType(ReportRunType.monthEndPack);
      await viewModel.load();

      // The pack is not in this user's catalogue, so the screen must not sit on
      // a report it cannot run.
      expect(viewModel.selectedType, ReportRunType.salesSummary);
    });

    test('the accounting calendar arrives with the catalogue', () async {
      final viewModel = FakeReportRepository(
        lockedThrough: DateTime(2026, 8, 31),
      ).viewModel();
      await viewModel.load();

      expect(viewModel.lock.lockedThrough, DateTime(2026, 8, 31));
      expect(viewModel.lock.canManage, isTrue);
    });
  });

  group('the run history', () {
    test('verifying a run reports whether the figures still hold', () async {
      final repository = FakeReportRepository();
      final viewModel = repository.viewModel();

      final verification = await viewModel.verifyRun(3);
      expect(verification?.matches, isTrue);
      expect(repository.verifyCalls, 1);
      expect(viewModel.verifyingRunId, isNull);
    });
  });
}
