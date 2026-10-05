import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/stock_transfer.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/inventory/views/transfer_unit_picks.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A transfer names its handsets on the shared picker (§6.5): from the shelf
/// the van leaves, identified stock only, scanned or ticked, exactly the line's
/// base quantity — and the answer comes back as the transfer's own picks.
void main() {
  const transfer = StockTransfer(
    id: 7,
    transferNumber: 'TR-7',
    sourceId: 3,
    sourceName: 'المخزن',
    destinationId: 4,
    destinationName: 'الفرع',
    status: StockTransferStatus.draft,
    lines: [
      StockTransferLine(
        id: 11,
        variantId: 5,
        variantName: 'آيفون 13',
        variantSku: 'IP13',
        quantity: 2,
        baseQuantity: 2,
        trackingMode: TrackingMode.serial,
      ),
      StockTransferLine(
        id: 12,
        variantId: 6,
        variantName: 'شاحن',
        variantSku: 'CHG',
        quantity: 10,
        baseQuantity: 10,
      ),
    ],
  );

  test('only serialised lines ask for articles, at their base quantity', () {
    expect(transferNeedsUnitPicks(transfer), isTrue);
    final lines = transferUnitPickLines(transfer);
    expect(lines, hasLength(1));
    expect(lines.single.key, 11);
    expect(lines.single.count, 2);
    expect(lines.single.variantId, 5);
  });

  testWidgets('loads from the source shelf, takes a scan, returns the picks', (
    tester,
  ) async {
    final repository = _FakeTrackedStockRepository();
    late Future<Map<int, TransferLinePick>?> result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = pickTransferUnits(
                  context,
                  transfer: transfer,
                  repository: repository,
                );
              },
              child: const Text('افتح'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('افتح'));
    await tester.pumpAndSettle();

    final first = repository.requests.first;
    expect(first.warehouseId, 3);
    expect(first.status, StockUnitStatus.inStock);
    expect(first.isIdentified, isTrue);

    await tester.tap(find.text('3512-A'));
    await tester.enterText(find.byType(TextField), '3512-FAR');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(repository.requests.last.code, '3512-FAR');

    await tester.tap(find.widgetWithText(FilledButton, 'إرسال'));
    await tester.pumpAndSettle();

    final picks = await result;
    expect(picks!.keys, [11]);
    expect(picks[11]!.unitIds, unorderedEquals([1, 99]));
  });
}

class _Request {
  const _Request(this.warehouseId, this.status, this.isIdentified, this.code);

  final int? warehouseId;
  final String status;
  final bool? isIdentified;
  final String code;
}

class _FakeTrackedStockRepository extends TrackedStockRepository {
  _FakeTrackedStockRepository() : super(PosApiService());

  final List<_Request> requests = [];

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
    requests.add(_Request(warehouseId, status, isIdentified, code));
    if (code.isNotEmpty) {
      return Ok(
        StockUnitPage(
          units: [StockUnit(id: 99, variantId: variantId!, code: code)],
        ),
      );
    }
    return Ok(
      StockUnitPage(
        units: [
          StockUnit(id: 1, variantId: variantId!, code: '3512-A'),
          StockUnit(id: 2, variantId: variantId, code: '3512-B'),
        ],
      ),
    );
  }
}
