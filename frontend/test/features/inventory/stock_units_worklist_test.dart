import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/inventory/view_models/tracked_stock_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/views/stock_units_screen.dart';

/// The articles still owed a number — received before they were scanned, or
/// opened as stock — and the way to give them one.
///
/// They used to be a count in a callout and nothing else: the repository could
/// name a placeholder, and no screen ever called it, so a shop that received
/// "now, scan later" had handsets the till refused to sell, forever.
void main() {
  testWidgets('the worklist lists the placeholders and names them one by one', (
    tester,
  ) async {
    final repository = _FakeTrackedStockRepository();
    final viewModel = TrackedStockViewModel(repository);
    addTearDown(viewModel.dispose);
    final capabilities = AuthorizationCapabilities.forUser(
      const PosUser(
        id: 1,
        username: 'manager',
        role: UserRole.manager,
        isActive: true,
        serializedInventoryEnabled: true,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StockUnitsScreen(
          viewModel: viewModel,
          capabilities: capabilities,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.tap(find.text(l10n.stockUnitsShowMissing));
    await tester.pumpAndSettle();

    // Asked for exactly the worklist: on the shelf and still unnamed.
    expect(repository.lastIsIdentified, isFalse);
    expect(repository.lastInStock, isTrue);
    expect(find.text(l10n.stockUnitsAwaitingIdentifier), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('stock_unit_identify_7')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('identify_unit_code_field')),
      '351234567890116',
    );
    await tester.tap(find.byKey(const ValueKey('identify_unit_save')));
    await tester.pumpAndSettle();

    expect(repository.identified, {7: '351234567890116'});
    // Named, so off the list of the unnamed.
    expect(find.byKey(const ValueKey('stock_unit_identify_7')), findsNothing);
    expect(find.text(l10n.stockUnitIdentified), findsOne);
  });
}

class _FakeTrackedStockRepository extends TrackedStockRepository {
  _FakeTrackedStockRepository() : super(PosApiService());

  bool? lastIsIdentified;
  bool? lastInStock;
  final identified = <int, String>{};

  static const _placeholder = StockUnit(
    id: 7,
    variantId: 1,
    code: '',
    isIdentified: false,
    productName: 'آيفون 13',
  );

  @override
  Future<Result<StockUnitPage>> loadUnits({
    int? variantId,
    int? productId,
    int? warehouseId,
    String status = '',
    String code = '',
    bool? isIdentified,
    bool? inStock,
    bool forSale = false,
    int page = 1,
  }) async {
    lastIsIdentified = isIdentified;
    lastInStock = inStock;
    return const Ok(StockUnitPage(units: [_placeholder]));
  }

  @override
  Future<Result<StockUnitSummary>> loadUnitSummary({int? warehouseId}) async {
    return Ok(StockUnitSummary(missingIdentifiers: identified.isEmpty ? 1 : 0));
  }

  @override
  Future<Result<StockUnit>> identifyUnit(
    int unitId, {
    required String code,
    String secondaryCode = '',
    String identifierKind = '',
  }) async {
    identified[unitId] = code;
    return Ok(
      StockUnit(id: unitId, variantId: 1, code: code, productName: 'آيفون 13'),
    );
  }
}
