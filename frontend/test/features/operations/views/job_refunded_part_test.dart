import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A part refunded on the job's invoice stays fitted, and the job may put it
/// back on the shelf; one the invoice still charges for may not.

const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
);

Map<String, Object?> _material(int id, String name, {bool? isBilled}) => {
  'id': id,
  'variant': id,
  'product_name': name,
  'variant_name': '',
  'quantity': '1',
  'unit_cost': '80.00',
  'unit_price': '120.00',
  'line_total': '120.00',
  'is_consumed': true,
  'is_billed': ?isBilled,
  'consumed_at': '2026-09-20T10:00:00Z',
};

OperationsJob _invoicedJob(List<Map<String, Object?>> materials) {
  return OperationsJob.fromJson({
    'id': 12,
    'job_number': 'REP-12',
    'job_type': 'repair',
    'status': 'open',
    'customer_name': 'زبون',
    'order': 90,
    'order_receipt_number': 'R-90',
    'settlement_state': 'settled',
    'custody_state': 'with_shop',
    'materials_total': '240.00',
    'materials': materials,
  });
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository(this.job) : super(PosApiService());

  final OperationsJob job;

  @override
  Future<Result<OperationsJob>> loadJob(int jobId) async => Ok(job);
}

Future<void> _pump(WidgetTester tester, OperationsJob job) async {
  final repository = _FakeOperationsRepository(job);
  final viewModel = JobDetailsViewModel(repository, jobId: job.id);
  addTearDown(viewModel.dispose);
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
      theme: PointyTheme.light(),
      home: JobDetailsScreen(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(_manager),
        currentUser: _manager,
        catalogRepository: CatalogRepository(PosApiService()),
        operationsRepository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _rowOf(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(Row));

void main() {
  testWidgets('a refunded part can be put back; a billed one cannot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      _invoicedJob([
        _material(1, 'شاشة مستردة', isBilled: false),
        _material(2, 'بطارية مفوترة', isBilled: true),
      ]),
    );

    expect(find.text('استُرد ثمنها'), findsOneWidget);
    expect(find.text('خُصمت من المخزون'), findsOneWidget);
    expect(find.byTooltip('إرجاع للمخزون'), findsOneWidget);
    expect(
      find.descendant(
        of: _rowOf('شاشة مستردة').last,
        matching: find.text('استُرد ثمنها'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an invoiced job from an older server offers no put-back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(tester, _invoicedJob([_material(1, 'شاشة')]));

    expect(find.text('خُصمت من المخزون'), findsOneWidget);
    expect(find.text('استُرد ثمنها'), findsNothing);
    expect(find.byTooltip('إرجاع للمخزون'), findsNothing);
  });
}
