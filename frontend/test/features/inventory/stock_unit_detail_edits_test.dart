import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/consignment.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/receipt_capture.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/data/models/unit_photo.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/inventory/view_models/tracked_stock_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/views/stock_unit_detail_screen.dart';
import 'package:pointy_frontend/src/features/inventory/views/unit_capture_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_unit_picker_sheet.dart';
import 'package:pointy_frontend/src/shared/product_image_thumbnail.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_attribute_catalog.dart';

/// The unit page's three edits — the condition checklist, the photos and the
/// article's own warranty date — and the same checklist at intake.
void main() {
  group('the unit page', () {
    testWidgets('shows the facts by label, the cover and the photo strip', (
      tester,
    ) async {
      final repository = _FakeRepository();
      await _pumpDetail(tester, repository, permissions: _clerk);

      // Labels and display values from the server, never raw keys or codes.
      expect(find.text('صحة البطارية'), findsOneWidget);
      expect(find.text('92%'), findsOneWidget);
      expect(find.text('ممتاز +'), findsOneWidget);
      expect(find.text('a_plus'), findsNothing);
      // The yes/no fact reads as a checklist pill.
      expect(find.text('الشاحن مرفق'), findsOneWidget);
      // Cover badge on the first photo of the strip.
      expect(find.text('الغلاف'), findsOneWidget);
      expect(find.text('صور الجهاز'), findsOneWidget);
      // On the shelf with no date of its own: the product's days apply.
      expect(find.text('حسب مدة ضمان المنتج'), findsOneWidget);
    });

    testWidgets('a refused value is shown beside its field, in Arabic', (
      tester,
    ) async {
      final repository = _FakeRepository(
        attributeRefusal: const PosApiException(
          message: 'refused',
          statusCode: 400,
          responseBody:
              '{"attributes": {"battery_health": ["«صحة البطارية» نسبة بين 0 و 100."]}}',
        ),
      );
      await _pumpDetail(tester, repository, permissions: _clerk);

      await tester.tap(find.byKey(const ValueKey('unit-attributes-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('unit-attribute-battery_health')),
        '140',
      );
      await tester.tap(find.byKey(const ValueKey('unit-details-save')));
      await tester.pumpAndSettle();

      expect(find.text('«صحة البطارية» نسبة بين 0 و 100.'), findsOneWidget);
      // The sheet stays open with what was typed.
      expect(find.byKey(const ValueKey('unit-details-save')), findsOneWidget);
      expect(repository.savedAttributes?['battery_health'], 140);
    });

    testWidgets('the checklist is saved as the whole set, in typed values', (
      tester,
    ) async {
      final repository = _FakeRepository();
      await _pumpDetail(tester, repository, permissions: _clerk);

      await tester.tap(find.byKey(const ValueKey('unit-attributes-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('unit-attribute-battery_health')),
        '88',
      );
      await tester.tap(find.text('جيد'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('unit-details-save')));
      await tester.pumpAndSettle();

      expect(repository.savedAttributes, {
        'battery_health': 88,
        'condition_grade': 'b',
        'charger_included': true,
      });
      expect(find.byKey(const ValueKey('unit-details-save')), findsNothing);
    });

    testWidgets('a required field is asked for before anything is sent', (
      tester,
    ) async {
      final repository = _FakeRepository(requireGrade: true);
      await _pumpDetail(tester, repository, permissions: _clerk);

      await tester.tap(find.byKey(const ValueKey('unit-attributes-edit')));
      await tester.pumpAndSettle();
      // Clear the grade by tapping the chosen chip again.
      await tester.tap(find.text('ممتاز +').last);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('unit-details-save')));
      await tester.pumpAndSettle();

      expect(find.text('«درجة الحالة» مطلوب.'), findsOneWidget);
      expect(repository.savedAttributes, isNull);
    });

    testWidgets('a cashier sees the record but none of the edits', (
      tester,
    ) async {
      await _pumpDetail(tester, _FakeRepository(), permissions: _cashier);

      expect(find.byKey(const ValueKey('unit-attributes-edit')), findsNothing);
      expect(find.byKey(const ValueKey('unit-photos-add')), findsNothing);
      expect(
        find.byKey(const ValueKey('stock_unit_detail_warranty')),
        findsNothing,
      );
      expect(find.text('ممتاز +'), findsOneWidget);
    });

    testWidgets('the warranty date is a supervisor\'s edit', (tester) async {
      final repository = _FakeRepository();
      await _pumpDetail(
        tester,
        repository,
        permissions: [..._clerk, 'inventory.change_stockunit_warranty'],
      );

      await tester.tap(
        find.byKey(const ValueKey('stock_unit_detail_warranty')),
      );
      await tester.pumpAndSettle();
      expect(find.text('ينتهي ضمان هذا الجهاز في'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('unit-details-save')));
      await tester.pumpAndSettle();
      // Saved unchanged (no date) — the call is made, with null.
      expect(repository.warrantyCalls, 1);
    });
  });

  testWidgets('the till picker shows each handset\'s facts and its face', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showPosUnitPickerSheet(
                  context,
                  repository: _FakeRepository(),
                  variantId: 3,
                  productLabel: 'iPhone 14',
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

    expect(
      find.text('صحة البطارية 92% · درجة الحالة ممتاز + · الشاحن مرفق'),
      findsOneWidget,
    );
    expect(find.byType(ProductImageThumbnail), findsOneWidget);
  });

  group('intake', () {
    testWidgets('each scanned article can carry its checklist and its date', (
      tester,
    ) async {
      List<ReceiptUnitCapture>? captured;
      await tester.pumpWidget(
        _app(
          catalog: UnitAttributeCatalog((_) async => Ok(_definitions())),
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    captured = await showUnitCaptureSheet(
                      context,
                      productLabel: 'iPhone 14',
                      expectedCount: 1,
                      lineUnitCost: 1500,
                      assetTypeId: 3,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '351234567890116');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('unit-capture-details-351234567890116')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('unit-attribute-battery_health')),
        '91',
      );
      await tester.tap(find.byKey(const ValueKey('unit-details-save')));
      await tester.pumpAndSettle();

      // The row says what was recorded, on one line.
      expect(find.textContaining('صحة البطارية 91%'), findsOneWidget);

      await tester.tap(find.text('تأكيد المعرّفات').last);
      await tester.pumpAndSettle();
      expect(captured, hasLength(1));
      expect(captured!.single.toJson()['attributes'], {'battery_health': 91});
    });

    test('a capture sends its checklist and its own warranty date', () {
      final json = ReceiptUnitCapture(
        code: 'VIN123',
        attributes: const {'mileage': 12000},
        warrantyOverrideExpiresOn: DateTime(2028, 3, 1),
      ).toJson();
      expect(json['attributes'], {'mileage': 12000});
      expect(json['warranty_override_expires_on'], '2028-03-01');
    });

    test('a receipt line names the cover the sale stamped', () {
      final identifier = SaleLineIdentifier.fromJson(const {
        'kind': 'unit',
        'code': '351234567890116',
        'warranty_expires_on': '2027-10-05',
      });
      expect(identifier.warrantyExpiresOn, DateTime(2027, 10, 5));
    });
  });
}

const _clerk = [
  'inventory.view_stockunit',
  'inventory.change_stockunit',
  'inventory.manage_stockunit_photos',
];
const _cashier = ['inventory.view_stockunit'];

List<UnitAttributeDefinition> _definitions({bool requireGrade = false}) => [
  const UnitAttributeDefinition(
    key: 'battery_health',
    label: 'صحة البطارية',
    dataType: UnitAttributeType.percent,
    suffix: '%',
  ),
  UnitAttributeDefinition(
    key: 'condition_grade',
    label: 'درجة الحالة',
    dataType: UnitAttributeType.choice,
    isRequired: requireGrade,
    choices: const [
      UnitAttributeChoice(value: 'a_plus', label: 'ممتاز +'),
      UnitAttributeChoice(value: 'b', label: 'جيد'),
    ],
  ),
  const UnitAttributeDefinition(
    key: 'charger_included',
    label: 'الشاحن مرفق',
    dataType: UnitAttributeType.boolean,
  ),
];

Map<String, Object?> _unitJson() => {
  'id': 7,
  'variant': 3,
  'asset_type': 3,
  'code': '351234567890116',
  'identifier_kind': 'imei',
  'status': StockUnitStatus.inStock,
  'product_name': 'iPhone 14',
  'is_identified': true,
  'list_price': '1800.00',
  'attributes': {
    'battery_health': 92,
    'condition_grade': 'a_plus',
    'charger_included': true,
  },
  'attribute_display': [
    {
      'key': 'battery_health',
      'label': 'صحة البطارية',
      'value': 92,
      'display': '92%',
      'data_type': 'percent',
    },
    {
      'key': 'condition_grade',
      'label': 'درجة الحالة',
      'value': 'a_plus',
      'display': 'ممتاز +',
      'data_type': 'choice',
    },
    {
      'key': 'charger_included',
      'label': 'الشاحن مرفق',
      'value': true,
      'display': 'نعم',
      'data_type': 'bool',
    },
  ],
  'cover_photo': _photoJson(1, cover: true),
};

Map<String, Object?> _photoJson(int id, {bool cover = false}) => {
  'id': id,
  'content_url': '',
  'thumbnail_url': '',
  'is_cover': cover,
  'original_filename': 'front.jpg',
};

class _FakeRepository extends TrackedStockRepository {
  _FakeRepository({this.attributeRefusal, this.requireGrade = false})
    : super(PosApiService());

  final PosApiException? attributeRefusal;
  final bool requireGrade;
  Map<String, Object?>? savedAttributes;
  int warrantyCalls = 0;

  StockUnit get _unit => StockUnit.fromJson(_unitJson());

  @override
  Future<Result<StockUnit>> loadUnit(int unitId) async => Ok(_unit);

  @override
  Future<Result<StockUnitPage>> loadSellableUnits({
    required int variantId,
  }) async => Ok(StockUnitPage(units: [_unit], count: 1));

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
  Future<Result<List<UnitPhoto>>> loadUnitPhotos(int unitId) async => Ok([
    UnitPhoto.fromJson(_photoJson(1, cover: true)),
    UnitPhoto.fromJson(_photoJson(2)),
  ]);

  @override
  Future<Result<List<UnitAttributeDefinition>>> loadAttributeDefinitions(
    int assetTypeId,
  ) async => Ok(_definitions(requireGrade: requireGrade));

  @override
  Future<Result<StockUnit>> saveUnitAttributes(
    int unitId,
    Map<String, Object?> attributes,
  ) async {
    savedAttributes = attributes;
    final refusal = attributeRefusal;
    if (refusal != null) return Error(refusal);
    return Ok(_unit);
  }

  @override
  Future<Result<StockUnit>> setUnitWarrantyOverride(
    int unitId,
    DateTime? expiresOn,
  ) async {
    warrantyCalls += 1;
    return Ok(_unit);
  }
}

/// [catalog] is installed above the Navigator, as the app installs it, so a
/// sheet pushed as its own route can reach it.
Widget _app(Widget home, {UnitAttributeCatalog? catalog}) => MaterialApp(
  builder: catalog == null
      ? null
      : (context, child) => UnitAttributeCatalogScope(
          catalog: catalog,
          child: child ?? const SizedBox.shrink(),
        ),
  locale: const Locale('ar'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: PointyTheme.light(),
  home: home,
);

Future<void> _pumpDetail(
  WidgetTester tester,
  _FakeRepository repository, {
  required List<String> permissions,
}) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final capabilities = AuthorizationCapabilities.forUser(
    PosUser.fromJson({
      'id': 2,
      'username': 'clerk',
      'role': 'cashier',
      'serialized_inventory_enabled': true,
      'permissions': permissions,
    }),
  );
  final unit = StockUnit.fromJson(_unitJson());
  await tester.pumpWidget(
    _app(
      StockUnitDetailScreen(
        viewModel: TrackedStockViewModel(repository),
        unit: unit,
        capabilities: capabilities,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
