import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_labels.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

PurchaseOrderLine _line({
  required int id,
  required int variantId,
  required String name,
  required double quantity,
  double received = 0,
  double unitFactor = 1,
  String barcode = '',
  TrackingMode trackingMode = TrackingMode.quantity,
}) {
  return PurchaseOrderLine(
    id: id,
    productId: variantId,
    variantId: variantId,
    quantity: quantity,
    adjustedQuantity: 0,
    adjustableQuantity: 0,
    receivedQuantity: received,
    damagedQuantity: 0,
    rejectedQuantity: 0,
    openQuantity: quantity - received,
    hasReceivingTotals: received > 0,
    unitCost: 10,
    total: 10 * quantity,
    productName: name,
    variantBarcode: barcode,
    unitFactor: unitFactor,
    sellingPrice: 15,
    trackingMode: trackingMode,
  );
}

/// The order's products print as stickers in one go, already counted.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  test('counts pieces: received when any arrived, otherwise ordered', () {
    final entries = purchaseOrderLabelEntries(
      lines: [
        // 3 cartons of 12 ordered, 2 received → 24 pieces arrived.
        _line(
          id: 1,
          variantId: 1,
          name: 'مياه',
          quantity: 3,
          received: 2,
          unitFactor: 12,
          barcode: '111',
        ),
        // The same water by the piece, on its own line: one row, summed.
        _line(
          id: 2,
          variantId: 1,
          name: 'مياه',
          quantity: 6,
          received: 6,
          barcode: '111',
        ),
        // Nothing received yet: the ordered count.
        _line(id: 3, variantId: 2, name: 'عصير', quantity: 5, barcode: '222'),
        _line(
          id: 4,
          variantId: 3,
          name: 'هاتف',
          quantity: 2,
          barcode: '333',
          trackingMode: TrackingMode.serial,
        ),
        _line(id: 5, variantId: 4, name: 'بلا باركود', quantity: 4),
      ],
      l10n: l10n,
    );

    expect(entries.map((entry) => entry.title), [
      'مياه',
      'عصير',
      'هاتف',
      'بلا باركود',
    ]);
    expect(entries.map((entry) => entry.stickerCount), [30, 5, 2, 4]);
    expect(entries.map((entry) => entry.printable), [true, true, false, false]);
    // A handset's sticker is its own number, never the variant's barcode.
    expect(entries[2].unavailableReason, l10n.purchaseOrderLabelsSerialized);
  });

  testWidgets('prints the ticked products at their counts, typed or not', (
    tester,
  ) async {
    final printing = _Printing();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showPurchaseOrderLabelsSheet(
                  context,
                  lines: [
                    _line(
                      id: 1,
                      variantId: 1,
                      name: 'مياه',
                      quantity: 12,
                      barcode: '111',
                    ),
                    _line(
                      id: 2,
                      variantId: 2,
                      name: 'عصير',
                      quantity: 5,
                      barcode: '222',
                    ),
                    _line(
                      id: 3,
                      variantId: 3,
                      name: 'حليب',
                      quantity: 2,
                      barcode: '333',
                    ),
                  ],
                  printingRepository: printing,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Everything printable starts ticked; select-all clears, then restores.
    await tester.tap(find.byKey(const ValueKey('label-batch-select-all')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.labelBatchPrintCount(0)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('label-batch-select-all')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.labelBatchPrintCount(19)), findsOneWidget);

    // Untick the milk, type a count for the juice.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('label-batch-entry-2')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('label-batch-entry-1')),
        matching: find.byType(TextField),
      ),
      '40',
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.labelBatchPrintCount(52)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('label-batch-print')));
    await tester.pumpAndSettle();

    final lines = printing.printed.single;
    expect(lines.map((line) => line.label.barcode), ['111', '222']);
    expect(lines.map((line) => line.copies), [12, 40]);
  });
}

class _Printing extends PrintingRepository {
  _Printing() : super(PosApiService());

  final List<List<BarcodeLabelPrintLine>> printed = [];

  @override
  Future<PrintTransportResult> printBarcodeLabels(
    List<BarcodeLabelPrintLine> lines,
  ) async {
    printed.add(lines);
    return const PrintTransportResult.success('ok');
  }
}
