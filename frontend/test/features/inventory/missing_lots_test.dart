import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/missing_lot.dart';
import 'package:pointy_frontend/src/data/models/stock_batch.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/inventory/view_models/missing_lots_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/views/missing_lots_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The missing-lot worklist: grandfathered packs scanned or ticked, put into
/// a lot that exists or one typed off the box, and gone from the list after.
void main() {
  group('MissingLotsViewModel', () {
    test('one product to work is opened without a tap', () async {
      final repository = _FakeRepository();
      final viewModel = MissingLotsViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.load();

      expect(viewModel.variantId, 5);
      expect(viewModel.units.map((unit) => unit.code), ['PACK-1', 'PACK-2']);
      expect(viewModel.lots.single.code, 'LOT-A');
    });

    test('a scan ticks the pack, past the first page too', () async {
      final repository = _FakeRepository();
      final viewModel = MissingLotsViewModel(repository);
      addTearDown(viewModel.dispose);
      await viewModel.load();

      expect(await viewModel.scan('pack-1'), MissingLotScanOutcome.selected);
      expect(
        await viewModel.scan('PACK 1'),
        MissingLotScanOutcome.alreadySelected,
      );
      expect(await viewModel.scan('FAR-9'), MissingLotScanOutcome.selected);
      expect(await viewModel.scan('NOPE'), MissingLotScanOutcome.notFound);

      expect(viewModel.selected, {1, 99});
      expect(viewModel.units.first.code, 'FAR-9');
      expect(repository.searchedCodes, ['FAR-9', 'NOPE']);
    });

    test('assigned packs leave the list and the count drops', () async {
      final repository = _FakeRepository();
      final viewModel = MissingLotsViewModel(repository);
      addTearDown(viewModel.dispose);
      await viewModel.load();
      viewModel.toggle(2);

      final done = await viewModel.assign(const LotChoice.existing(7));

      expect(done?.assigned, 1);
      expect(repository.assignments.single.unitIds, [2]);
      expect(repository.assignments.single.lot.batchId, 7);
      expect(viewModel.units.map((unit) => unit.id), [1]);
      expect(viewModel.groups.single.count, 1);
      expect(viewModel.selectedCount, 0);
    });

    test('the last pack of a product takes the product off the list', () async {
      final repository = _FakeRepository(count: 1);
      final viewModel = MissingLotsViewModel(repository);
      addTearDown(viewModel.dispose);
      await viewModel.load();
      viewModel.toggle(1);

      await viewModel.assign(LotChoice.create('LOT-NEW'));

      expect(viewModel.groups, isEmpty);
      expect(viewModel.variantId, isNull);
      expect(repository.assignments.single.lot.toJson(), {
        'lot_code': 'LOT-NEW',
      });
    });

    test('a refused assignment keeps the selection to fix and retry', () async {
      final repository = _FakeRepository(refuse: true);
      final viewModel = MissingLotsViewModel(repository);
      addTearDown(viewModel.dispose);
      await viewModel.load();
      viewModel.toggle(1);

      expect(await viewModel.assign(LotChoice.create('X')), isNull);
      expect(viewModel.assignError, isNotNull);
      expect(viewModel.selected, {1});
      expect(viewModel.groups.single.count, 2);
    });
  });

  testWidgets('tick, choose a new lot with its date, and it is assigned', (
    tester,
  ) async {
    final repository = _FakeRepository(expiryRequired: true);
    final viewModel = MissingLotsViewModel(repository);
    addTearDown(viewModel.dispose);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: MissingLotsScreen(viewModel: viewModel, canAssign: true),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    expect(find.text('PACK-1'), findsOne);
    await tester.tap(find.byKey(const ValueKey('missing_lots_select_all')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.missingLotsSelected(2)), findsOne);

    await tester.tap(find.byKey(const ValueKey('missing_lots_assign')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('lot_chooser_confirm'));
    // Nothing is chosen for the person: a default lot is a recall that misses.
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('lot_choice_new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('lot_chooser_code')),
      'LOT-2030',
    );
    await tester.pumpAndSettle();
    // This product owes a date, as at receiving.
    expect(find.text(l10n.lotChooserExpiryNeeded), findsOne);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.text(l10n.batchCaptureExpiryShortcut(12)));
    await tester.pumpAndSettle();

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    final sent = repository.assignments.single;
    expect(sent.unitIds, [1, 2]);
    expect(sent.lot.code, 'LOT-2030');
    expect(sent.lot.expiryDate, isNotNull);
    expect(find.text(l10n.missingLotsAssigned(2, 'LOT-2030')), findsOne);
    expect(find.text(l10n.missingLotsEmpty), findsOne);
  });
}

class _Assignment {
  const _Assignment(this.unitIds, this.lot);

  final List<int> unitIds;
  final LotChoice lot;
}

class _FakeRepository extends TrackedStockRepository {
  _FakeRepository({
    this.count = 2,
    this.refuse = false,
    this.expiryRequired = false,
  }) : super(PosApiService());

  final int count;
  final bool refuse;
  final bool expiryRequired;
  final List<String> searchedCodes = [];
  final List<_Assignment> assignments = [];

  @override
  Future<Result<List<MissingLotGroup>>> loadMissingLotGroups({
    int? productId,
  }) async {
    final left =
        count -
        assignments.fold<int>(0, (sum, row) => sum + row.unitIds.length);
    return Ok([
      if (left > 0)
        MissingLotGroup(
          variantId: 5,
          productId: 3,
          productName: 'أنسولين',
          count: left,
          expiryRequired: expiryRequired,
        ),
    ]);
  }

  @override
  Future<Result<StockUnitPage>> loadMissingLotUnits({
    required int variantId,
    String code = '',
    int page = 1,
  }) async {
    if (code.isNotEmpty) {
      searchedCodes.add(code);
      return Ok(
        StockUnitPage(
          units: [
            if (code == 'FAR-9')
              StockUnit(id: 99, variantId: variantId, code: 'FAR-9'),
          ],
        ),
      );
    }
    return Ok(
      StockUnitPage(
        units: [
          for (var id = 1; id <= count; id++)
            StockUnit(id: id, variantId: variantId, code: 'PACK-$id'),
        ],
      ),
    );
  }

  @override
  Future<Result<StockBatchPage>> loadBatches({
    int? variantId,
    int? productId,
    int? warehouseId,
    String status = '',
    bool? isExpired,
    bool forSale = false,
    int page = 1,
  }) async {
    return Ok(
      StockBatchPage(
        batches: [
          StockBatch.fromJson({
            'id': 7,
            'variant': variantId,
            'code': 'LOT-A',
            'display_code': 'LOT-A',
            'expiry_date': '2029-06-30',
            'status': 'active',
            'is_sellable': true,
          }),
        ],
      ),
    );
  }

  @override
  Future<Result<LotAssignment>> assignLot({
    required int variantId,
    required List<int> unitIds,
    required LotChoice lot,
  }) async {
    if (refuse) {
      return Error(Exception('refused'));
    }
    assignments.add(_Assignment(unitIds, lot));
    return Ok(
      LotAssignment(
        batchId: lot.batchId ?? 70,
        batchCode: lot.isNew ? lot.code : 'LOT-A',
        created: lot.isNew,
        assigned: unitIds.length,
      ),
    );
  }
}
