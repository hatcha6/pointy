import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/consignment.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/models/unit_photo.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/inventory/view_models/tracked_stock_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/views/stock_unit_detail_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

/// The counter is where a consignor comes to collect, so the unit screen has
/// to say what the shop owes them. It used to read that from the unit's cost —
/// which is masked from the very cashier handing the money over — and told
/// them the owner was owed 0.00. It now reads the payout figures the server
/// sends to whoever may see consignment liabilities, and says nothing at all
/// when it was not told.
void main() {
  test('absent payout figures stay absent', () {
    final unit = StockUnit.fromJson(_soldConsignment());

    expect(unit.awaitsPayout, isTrue);
    expect(unit.netDue, isNull, reason: 'not told, not "owed nothing"');
    expect(unit.payoutDue, isNull);
  });

  testWidgets('a cashier sees what to hand over, though not the cost', (
    tester,
  ) async {
    await _pump(
      tester,
      _soldConsignment(
        payout: const {
          'payout_due': '10000.00',
          'consignor_advance': '0.00',
          'net_due': '10000.00',
        },
      ),
    );

    expect(find.text('المستحق لصاحبها'), findsOneWidget);
    expect(find.text(formatMoney(10000)), findsOneWidget);
    expect(find.text(formatMoney(0)), findsNothing);
    // No advance, so no breakdown.
    expect(find.text('سبق صرفه لصاحبها'), findsNothing);
  });

  testWidgets('an advance is taken off, and the screen says why', (
    tester,
  ) async {
    await _pump(
      tester,
      _soldConsignment(
        payout: const {
          'payout_due': '10000.00',
          'consignor_advance': '1600.00',
          'net_due': '8400.00',
        },
      ),
    );

    expect(find.text('حصة صاحبها من البيع'), findsOneWidget);
    expect(find.text(formatMoney(10000)), findsOneWidget);
    expect(find.text('سبق صرفه لصاحبها'), findsOneWidget);
    expect(find.text('- ${formatMoney(1600)}'), findsOneWidget);
    expect(find.text(formatMoney(8400)), findsOneWidget);
  });

  testWidgets('a reader who is not told what is owed is not told 0.00', (
    tester,
  ) async {
    await _pump(tester, _soldConsignment());

    expect(find.text('بيانات الأمانة'), findsOneWidget);
    expect(find.text('المستحق لصاحبها'), findsNothing);
    expect(find.text(formatMoney(0)), findsNothing);
  });
}

/// A consigned watch, sold and not yet collected, as a reader without the
/// unit-cost permission gets it: no `incoming_rate`, no `total_cost`.
Map<String, Object?> _soldConsignment({
  Map<String, Object?> payout = const {},
}) {
  return {
    'id': 7,
    'variant': 3,
    'code': 'ROLEX-A',
    'identifier_kind': 'serial',
    'status': StockUnitStatus.sold,
    'product_name': 'ساعة',
    'is_identified': true,
    'is_consignment': true,
    'consignor': 4,
    'consignor_name': 'سالم',
    'declared_value': '12000.00',
    'consignor_paid_at': null,
    'sold_price': '12000.00',
    ...payout,
  };
}

Future<void> _pump(WidgetTester tester, Map<String, Object?> json) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final unit = StockUnit.fromJson(json);
  final capabilities = AuthorizationCapabilities.forUser(
    PosUser.fromJson({
      'id': 2,
      'username': 'cashier',
      'role': 'cashier',
      'permissions': const [
        'inventory.view_stockunit',
        'inventory.view_consignment_liability',
        'inventory.disburse_consignment_payout',
      ],
    }),
  );
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
      home: StockUnitDetailScreen(
        viewModel: TrackedStockViewModel(_UnitRepository(unit)),
        unit: unit,
        capabilities: capabilities,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Answers the screen's reloads with the unit it was given, and an empty past.
class _UnitRepository extends TrackedStockRepository {
  _UnitRepository(this.unit) : super(PosApiService());

  final StockUnit unit;

  @override
  Future<Result<StockUnit>> loadUnit(int unitId) async => Ok(unit);

  @override
  Future<Result<List<StockAllocationEntry>>> loadUnitHistory(
    int unitId,
  ) async => Ok(const []);

  @override
  Future<Result<List<StockUnitTimelineEntry>>> loadUnitTimeline(
    int unitId,
  ) async => Ok(const []);

  @override
  Future<Result<List<ConsignmentIncident>>> loadUnitIncidents(
    int unitId,
  ) async => Ok(const []);

  @override
  Future<Result<List<UnitPhoto>>> loadUnitPhotos(int unitId) async =>
      Ok(const []);
}
