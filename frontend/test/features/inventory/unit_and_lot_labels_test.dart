import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/receipt_capture.dart';
import 'package:pointy_frontend/src/data/models/stock_batch.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/catalog/views/barcode_label_print_action.dart';
import 'package:pointy_frontend/src/features/inventory/view_models/tracked_stock_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/views/stock_batches_screen.dart';
import 'package:pointy_frontend/src/features/inventory/views/stock_unit_detail_screen.dart';
import 'package:pointy_frontend/src/features/inventory/views/stock_units_screen.dart';
import 'package:pointy_frontend/src/features/purchasing/views/receipt_labels.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Every handset and every lot can be told apart, priced and labelled.
void main() {
  late List<Uri> requested;
  late _Printing printing;

  setUp(() {
    requested = [];
    printing = _Printing();
  });

  PosApiService api() => PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient((request) async {
      requested.add(request.url);
      return http.Response(
        jsonEncode(_answer(request.url)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  group('the handsets list', () {
    testWidgets('a row names its variant, its condition and its price', (
      tester,
    ) async {
      await _pump(tester, (_) => _units(api(), printing));

      expect(find.textContaining('آيفون 13 - 128 جيجا · أزرق'), findsWidgets);
      expect(find.text('91% · ممتاز +'), findsOneWidget);
      expect(find.text('2650.00 د.ل'), findsOneWidget);
      expect(find.text('سعر البيع'), findsWidgets);
      // The cost, for a reader allowed it, is a second labelled figure.
      expect(find.text('التكلفة 2150.00 د.ل'), findsOneWidget);
    });

    testWidgets('a variant chip narrows the list to that variant', (
      tester,
    ) async {
      await _pump(tester, (_) => _units(api(), printing));

      await tester.tap(find.byKey(const ValueKey('variant_filter_1012')));
      await tester.pumpAndSettle();

      expect(
        _lastList(requested).queryParameters,
        containsPair('variant', '1012'),
      );
    });

    testWidgets(
      'chosen handsets print one sticker each, own number and price',
      (tester) async {
        await _pump(tester, (_) => _units(api(), printing));

        await tester.tap(
          find.byKey(const ValueKey('stock_units_select_for_labels')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('353012118845120'));
        await tester.tap(find.text('353012118847381'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('stock_units_print_selected')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('label-batch-print')));
        await tester.pumpAndSettle();

        final lines = printing.printed.single;
        expect(lines.map((line) => line.label.barcode), [
          '353012118845120',
          '353012118847381',
        ]);
        expect(lines.map((line) => line.label.unitPrice), [2650, 2450]);
      },
    );
  });

  group('the label dialog', () {
    testWidgets('a phone is never offered an expiry date', (tester) async {
      await _pump(
        tester,
        (context) => _opener(
          () => showBarcodeLabelPrintDialog(
            context: context,
            label: _draft,
            tracksExpiry: false,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(SwitchListTile), findsOneWidget); // price only
    });

    testWidgets('choosing a lot stamps its date and offers its quantity', (
      tester,
    ) async {
      BarcodeLabelPrintDialogResult? result;
      await _pump(
        tester,
        (context) => _opener(() async {
          result = await showBarcodeLabelPrintDialog(
            context: context,
            label: _draft,
            tracksExpiry: true,
            lots: [StockBatch.fromJson(_lot)],
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('barcode-label-lot')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('L5321-A').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('طباعة'));
      await tester.pumpAndSettle();

      expect(result!.expiryDate, DateTime(2027, 4, 30));
      expect(result!.copies, 15);
    });
  });

  group('the lots list', () {
    testWidgets('a lot names its variant and prints dated stickers', (
      tester,
    ) async {
      await _pump(tester, (_) => _lots(api(), printing));

      expect(find.text('حليب أطفال نان 1 - 400 غ'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('stock_batch_labels_70')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('طباعة'));
      await tester.pumpAndSettle();

      final line = printing.printed.single.single;
      expect(line.label.barcode, '6221000000017');
      expect(line.expiryDate, DateTime(2027, 4, 30));
      expect(line.copies, 15);
    });

    testWidgets('a serial-in-lot carton opens onto its handsets', (
      tester,
    ) async {
      await _pump(tester, (_) => _lots(api(), printing));

      await tester.tap(find.byKey(const ValueKey('stock_batch_units_71')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('stock_units_batch_filter')), findsOne);
      expect(_lastList(requested).queryParameters, containsPair('batch', '71'));
    });
  });

  testWidgets('a handset page names the variant and prints its own label', (
    tester,
  ) async {
    await _pump(tester, (_) {
      final repository = TrackedStockRepository(api());
      return StockUnitDetailScreen(
        viewModel: TrackedStockViewModel(repository),
        unit: StockUnit.fromJson(_unitJson()),
        capabilities: _caps,
        printingRepository: printing,
      );
    });

    expect(find.text('آيفون 13 - 128 جيجا · أزرق'), findsWidgets);
    await tester.tap(
      find.byKey(const ValueKey('stock_unit_detail_print_label')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('طباعة'));
    await tester.pumpAndSettle();

    final line = printing.printed.single.single;
    expect(line.label.barcode, '353012118845120');
    expect(line.label.unitPrice, 2650);
  });

  test(
    'a receipt offers stickers for the sound handsets and each lot',
    () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      const phoneLine = PurchaseOrderLine(
        id: 1,
        productId: 1,
        variantId: 1,
        quantity: 3,
        adjustedQuantity: 0,
        adjustableQuantity: 0,
        receivedQuantity: 0,
        damagedQuantity: 0,
        rejectedQuantity: 0,
        openQuantity: 3,
        hasReceivingTotals: false,
        unitCost: 1950,
        total: 5850,
        productName: 'آيفون 13 مستعمل',
        trackingMode: TrackingMode.serial,
        sellingPrice: 2600,
      );
      const milkLine = PurchaseOrderLine(
        id: 2,
        productId: 2,
        variantId: 2,
        quantity: 24,
        adjustedQuantity: 0,
        adjustableQuantity: 0,
        receivedQuantity: 0,
        damagedQuantity: 0,
        rejectedQuantity: 0,
        openQuantity: 24,
        hasReceivingTotals: false,
        unitCost: 36,
        total: 864,
        productName: 'حليب',
        trackingMode: TrackingMode.batch,
        variantBarcode: '6221000000017',
        sellingPrice: 48,
      );

      final entries = receiptLabelEntries(
        orderLines: const [phoneLine, milkLine],
        received: [
          PurchaseReceiveLineDraft(
            purchaseLineId: 1,
            quantityReceived: 2,
            quantityDamaged: 1,
            capture: const ReceiptLineCapture(
              units: [
                ReceiptUnitCapture(code: 'A1', listPrice: 2650),
                ReceiptUnitCapture(code: 'A2'),
                ReceiptUnitCapture(code: 'DAMAGED'),
              ],
            ),
          ),
          PurchaseReceiveLineDraft(
            purchaseLineId: 2,
            quantityReceived: 24,
            quantityDamaged: 0,
            capture: ReceiptLineCapture(
              batches: [
                ReceiptBatchCapture(
                  code: 'L-A',
                  quantity: 15,
                  expiryDate: DateTime(2027, 4, 30),
                ),
                ReceiptBatchCapture(
                  code: 'L-B',
                  quantity: 9,
                  expiryDate: DateTime(2027, 10, 31),
                ),
              ],
            ),
          ),
        ],
        l10n: l10n,
      );

      expect(entries, hasLength(3));
      // Two sound handsets — the damaged one gets no sticker — each its own
      // number, the second falling back to the shelf price.
      expect(entries.first.lines.map((line) => line.label.barcode), [
        'A1',
        'A2',
      ]);
      expect(entries.first.lines.map((line) => line.label.unitPrice), [
        2650,
        2600,
      ]);
      // A lot per entry, its copies its quantity, its date its own.
      expect(entries[1].lines.single.copies, 15);
      expect(entries[1].lines.single.expiryDate, DateTime(2027, 4, 30));
      expect(entries[2].lines.single.copies, 9);
      expect(entries[2].copiesEditable, isTrue);
    },
  );
}

// ---------------------------------------------------------------------------

final _manager = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
  'is_active': true,
  'serialized_inventory_enabled': true,
  'batch_tracking_enabled': true,
});

final _caps = AuthorizationCapabilities.forUser(_manager);

const _draft = BarcodeLabelDraft(
  displayName: 'حليب أطفال نان 1 - 400 غ',
  sku: 'NAN1-400',
  barcode: '6221000000017',
  unitPrice: 48,
);

final Map<String, Object?> _lot = {
  'id': 70,
  'variant': 2011,
  'product_name': 'حليب أطفال نان 1',
  'variant_name': 'حليب أطفال نان 1 - 400 غ',
  'variant_sku': 'NAN1-400',
  'variant_barcode': '6221000000017',
  'variant_price': '48.00',
  'tracking_mode': 'batch',
  'code': 'L5321-A',
  'display_code': 'L5321-A',
  'expiry_date': '2027-04-30',
  'status': 'active',
  'on_hand': '15.000',
};

final Map<String, Object?> _penLot = {
  ..._lot,
  'id': 71,
  'variant_name': 'قلم إنسولين - فليكس بن',
  'tracking_mode': 'serial_batch',
  'code': 'NV-24K118',
  'display_code': 'NV-24K118',
  'on_hand': '4.000',
};

Map<String, Object?> _unitJson({
  int id = 501,
  int variant = 1011,
  String code = '353012118845120',
  String price = '2650.00',
}) => {
  'id': id,
  'variant': variant,
  'code': code,
  'identifier_kind': 'imei',
  'status': 'in_stock',
  'product_name': 'آيفون 13',
  'variant_name': 'آيفون 13 - 128 جيجا · أزرق',
  'list_price': price,
  'asking_price': price,
  'total_cost': '2150.00',
  'attribute_display': [
    {
      'key': 'battery_health',
      'label': 'صحة البطارية',
      'display': '91%',
      'data_type': 'percent',
    },
    {
      'key': 'condition_grade',
      'label': 'درجة الحالة',
      'display': 'ممتاز +',
      'data_type': 'choice',
    },
  ],
};

/// The last request for the units list itself, past the summary beside it.
Uri _lastList(List<Uri> requested) =>
    requested.lastWhere((url) => url.path.endsWith('/stock-units/'));

Object? _answer(Uri url) {
  final path = url.path.replaceFirst('/api/', '');
  if (path == 'stock-units/501/') return _unitJson();
  if (path == 'stock-units/') {
    return {
      'results': [
        _unitJson(),
        {
          ..._unitJson(id: 502, code: '353012118847381', price: '2450.00'),
          'attribute_display': <Object?>[],
          'total_cost': null,
        },
      ],
      'next': null,
    };
  }
  if (path == 'stock-batches/') {
    return {
      'results': [_lot, _penLot],
      'next': null,
    };
  }
  return {'results': <Object?>[], 'next': null};
}

StockUnitsScreen _units(PosApiService api, PrintingRepository printing) {
  final repository = TrackedStockRepository(api);
  return StockUnitsScreen(
    viewModel: TrackedStockViewModel(repository)
      ..setProductFilter(
        101,
        name: 'آيفون 13',
        variants: const [
          (id: 1011, label: '128 جيجا · أزرق'),
          (id: 1012, label: '128 جيجا · منتصف الليل'),
        ],
      ),
    capabilities: _caps,
    repository: repository,
    printingRepository: printing,
  );
}

StockBatchesScreen _lots(PosApiService api, PrintingRepository printing) {
  final repository = TrackedStockRepository(api);
  return StockBatchesScreen(
    viewModel: TrackedStockViewModel(repository),
    repository: repository,
    printingRepository: printing,
    capabilities: _caps,
  );
}

Widget _opener(VoidCallback onOpen) => Scaffold(
  body: Center(
    child: FilledButton(onPressed: onOpen, child: const Text('open')),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  Widget Function(BuildContext context) home,
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
      home: Builder(builder: home),
    ),
  );
  await tester.pumpAndSettle();
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
