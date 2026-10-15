import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/catalog/views/created_product_labels.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

Product _product({
  required int id,
  required String name,
  String barcode = '',
  double stock = 0,
  bool isService = false,
  TrackingMode trackingMode = TrackingMode.quantity,
  List<ProductVariant> variants = const [],
}) {
  return Product(
    id: id,
    name: name,
    quantityOnHand: stock,
    isService: isService,
    trackingMode: trackingMode,
    // A product with generated variants has one of them as its default.
    defaultVariant: variants.isNotEmpty
        ? variants.first
        : ProductVariant(
            id: id * 10,
            productId: id,
            sku: 'SKU-$id',
            unitPrice: 5,
            barcode: barcode,
            isDefault: true,
            quantityOnHand: stock,
          ),
    variants: variants,
  );
}

/// What a run of new products just made prints as stickers in one go.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  test('one row per variant, counted by opening stock or one', () {
    final entries = createdProductLabelEntries(
      products: [
        _product(id: 1, name: 'مياه', barcode: '111', stock: 24),
        _product(id: 2, name: 'عصير', barcode: '222'),
        // Weighed opening stock still wants a whole sticker.
        _product(id: 3, name: 'جبن', barcode: '333', stock: 2.5),
        _product(
          id: 4,
          name: 'قميص',
          variants: const [
            ProductVariant(
              id: 41,
              productId: 4,
              sku: 'S',
              unitPrice: 30,
              name: 'صغير',
              barcode: '441',
              isDefault: true,
            ),
            ProductVariant(
              id: 42,
              productId: 4,
              sku: 'L',
              unitPrice: 30,
              name: 'كبير',
              barcode: '442',
              quantityOnHand: 3,
            ),
          ],
        ),
        _product(
          id: 5,
          name: 'هاتف',
          barcode: '555',
          trackingMode: TrackingMode.serial,
        ),
        _product(id: 6, name: 'بلا باركود'),
        // A service has nothing to stick a label on.
        _product(id: 7, name: 'صيانة', barcode: '777', isService: true),
      ],
      l10n: l10n,
    );

    expect(entries.map((entry) => entry.title), [
      'مياه',
      'عصير',
      'جبن',
      'قميص - صغير',
      'قميص - كبير',
      'هاتف',
      'بلا باركود',
    ]);
    expect(entries.map((entry) => entry.stickerCount), [24, 1, 3, 1, 3, 1, 1]);
    expect(entries.map((entry) => entry.printable), [
      true,
      true,
      true,
      true,
      true,
      false,
      false,
    ]);
    expect(entries[5].unavailableReason, l10n.purchaseOrderLabelsSerialized);
    expect(entries[6].unavailableReason, l10n.createdProductLabelsNoBarcode);
    expect(entries.first.lines.single.label.productName, 'مياه');
  });

  Future<void> pumpOpener(
    WidgetTester tester,
    List<Product> products,
    _Printing printing,
  ) async {
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
                onPressed: () => showCreatedProductLabelsSheet(
                  context,
                  products: products,
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
  }

  testWidgets('prints the run at its counts', (tester) async {
    final printing = _Printing();
    await pumpOpener(tester, [
      _product(id: 1, name: 'مياه', barcode: '111', stock: 6),
      _product(id: 2, name: 'عصير', barcode: '222'),
    ], printing);

    expect(find.text(l10n.createdProductLabelsTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('label-batch-print')));
    await tester.pumpAndSettle();

    final lines = printing.printed.single;
    expect(lines.map((line) => line.label.barcode), ['111', '222']);
    expect(lines.map((line) => line.copies), [6, 1]);
  });

  testWidgets('stays quiet when nothing could print', (tester) async {
    final printing = _Printing();
    await pumpOpener(tester, [
      _product(id: 1, name: 'بلا باركود'),
      _product(id: 2, name: 'صيانة', barcode: '222', isService: true),
    ], printing);

    expect(find.text(l10n.createdProductLabelsTitle), findsNothing);
    expect(printing.printed, isEmpty);
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
