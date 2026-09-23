import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/models/stock_count_draft.dart';
import 'package:pointy_frontend/src/data/models/stock_count_line.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/stock_count_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_counting_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The loop a counter actually walks, end to end, on a till with a keyboard:
///
///   type a name -> Enter -> type a number -> Enter -> next item
///
/// Every step of it used to be impossible. The resting screen was a button
/// that opened a dialog; the quantity was a read-only display driven by an
/// on-screen keypad; and the only way out of a selected item was to type a
/// number for it.
const _variants = [
  ProductVariant(
    id: 5,
    productId: 1,
    sku: 'CHP-SLT',
    displayName: 'شيبس بطاطس بالملح',
    unitPrice: 1,
  ),
  ProductVariant(
    id: 6,
    productId: 2,
    sku: 'WTR-600',
    displayName: 'مياه معدنية',
    unitPrice: 1,
  ),
];

/// A product that arrives in cartons of 24 — 1,935 of the first production
/// shop's products are packed like this.
final _packedVariant = ProductVariant(
  id: 7,
  productId: 3,
  sku: 'JUI-1L',
  displayName: 'عصير برتقال',
  unitPrice: 1,
  productDetail: const Product(
    id: 3,
    name: 'عصير برتقال',
    quantityOnHand: 0,
    unit: 'piece',
    units: [
      ProductUnit(
        unit: UnitOfMeasure(id: 9, code: 'carton', name: 'كرتونة'),
        factorToBase: 24,
      ),
    ],
  ),
);

StockCount _session({List<StockCountLine> lines = const []}) {
  return StockCount(
    id: 1,
    countNumber: 'SC-1',
    status: StockCountStatus.inProgress,
    scope: StockCountScope.full,
    expectedLineCount: 48,
    countedLineCount: lines.length,
    varianceLineCount: 0,
    lines: lines,
  );
}

Future<_Harness> _pump(
  WidgetTester tester, {
  StockCount? session,
  List<ProductVariant>? variants,
  double? systemQuantity,
  Size size = const Size(1100, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final stockCounts = _FakeStockCountRepository(systemQuantity: systemQuantity);
  final catalog = _FakeCatalogRepository(variants ?? _variants);
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
      home: StockCountCountingScreen(
        session: session ?? _session(),
        stockCountRepository: stockCounts,
        catalogRepository: catalog,
        capabilities: _capabilities(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(stockCounts, catalog);
}

class _Harness {
  _Harness(this.stockCounts, this.catalog);

  final _FakeStockCountRepository stockCounts;
  final _FakeCatalogRepository catalog;
}

AuthorizationCapabilities _capabilities() {
  return AuthorizationCapabilities.forUser(
    PosUser.fromJson({
      'id': 1,
      'username': 'manager',
      'role': 'manager',
      'permissions': const <String>[],
    }),
  );
}

final _searchField = find.byKey(const ValueKey('stock_count_search_field'));
final _quantityField = find.byKey(const ValueKey('stock_count_quantity_field'));

void main() {
  testWidgets('the resting surface is the search itself, not a button', (
    tester,
  ) async {
    final harness = await _pump(tester);

    expect(_searchField, findsOneWidget);
    // Both items are listed without anyone opening anything.
    expect(find.text('شيبس بطاطس بالملح'), findsOneWidget);
    expect(find.text('مياه معدنية'), findsOneWidget);
    expect(harness.catalog.queries.single.search, '');
  });

  testWidgets('type, Enter: the best match is in hand', (tester) async {
    await _pump(tester);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // Search gone, quantity field up and ready for the number.
    expect(_searchField, findsNothing);
    expect(_quantityField, findsOneWidget);
    expect(find.text('شيبس بطاطس بالملح'), findsOneWidget);
  });

  testWidgets('Enter on a term that matches nothing keeps the search up', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(_searchField, 'لا-شيء');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(_quantityField, findsNothing);
    expect(_searchField, findsOneWidget);
    expect(find.text('لا توجد أصناف مطابقة.'), findsWidgets);
  });

  testWidgets('type a number, Enter: the line is saved and the loop restarts', (
    tester,
  ) async {
    final harness = await _pump(tester);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.enterText(_quantityField, '12');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(harness.stockCounts.drafts.single.variantId, 5);
    expect(harness.stockCounts.drafts.single.countedQuantity, 12);
    // Back on the search, with an empty field: the next item starts clean.
    expect(_searchField, findsOneWidget);
    expect(_quantityField, findsNothing);
    expect(harness.catalog.queries.last.search, '');
  });

  testWidgets('a count far off the system is saved without stopping the loop', (
    tester,
  ) async {
    // The system says 240, the shelf holds 3. That gap is reconciliation's to
    // review. Asking about it here put a sheet over the search after the save,
    // and the counter's next keystrokes went nowhere.
    final harness = await _pump(tester, systemQuantity: 240);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.enterText(_quantityField, '3');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(harness.stockCounts.drafts.single.countedQuantity, 3);
    // Nothing on top of the screen: no sheet, no dialog, nothing to dismiss.
    expect(ModalRoute.of(tester.element(_searchField))!.isCurrent, isTrue);
    // Blind: the system's number never reaches the counting screen.
    expect(find.text('240'), findsNothing);
    // The caret is already in the search, waiting for the next name.
    final search = tester.widget<EditableText>(
      find.descendant(of: _searchField, matching: find.byType(EditableText)),
    );
    expect(search.focusNode.hasFocus, isTrue);

    await tester.enterText(_searchField, 'WTR');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(_quantityField, findsOneWidget);
    expect(find.text('مياه معدنية'), findsOneWidget);
  });

  testWidgets('the keypad and the keyboard write the same number', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.enterText(_quantityField, '4');
    await tester.pumpAndSettle();
    // A thumb on the on-screen keypad continues the typed number.
    await tester.tap(find.byKey(const ValueKey('payment_keypad_digit_5')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_quantityField).controller?.text,
      '45',
      reason: 'the keypad writes into the same field the keyboard does',
    );
  });

  testWidgets('back leaves the item without counting it', (tester) async {
    final harness = await _pump(tester);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(_quantityField, findsOneWidget);

    await tester.tap(find.text('رجوع'));
    await tester.pumpAndSettle();

    expect(_searchField, findsOneWidget);
    expect(_quantityField, findsNothing);
    expect(
      harness.stockCounts.drafts,
      isEmpty,
      reason: 'backing out counts nothing — that is the whole point',
    );
    // The word that found the item is still there: the counter picked the
    // wrong row, not the wrong search.
    expect(harness.catalog.queries.last.search, 'CHP');
  });

  testWidgets('a typed number is not thrown away without asking', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.enterText(_quantityField, '9');
    await tester.pumpAndSettle();

    await tester.tap(find.text('رجوع'));
    await tester.pumpAndSettle();

    // Still on the item, with the confirm up.
    expect(find.text('تجاهل التغييرات؟'), findsOneWidget);
    await tester.tap(find.text('متابعة التعديل'));
    await tester.pumpAndSettle();
    expect(_quantityField, findsOneWidget);
  });

  testWidgets('a packed item is counted in cartons, and stored in pieces', (
    tester,
  ) async {
    final harness = await _pump(tester, variants: [_packedVariant]);

    await tester.enterText(_searchField, 'JUI');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('كرتونة'));
    await tester.pumpAndSettle();
    await tester.enterText(_quantityField, '3');
    await tester.pumpAndSettle();

    // The number that will reach the shelf is on screen before Enter.
    expect(find.text('= 72 قطعة'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final draft = harness.stockCounts.drafts.single;
    expect(draft.countedQuantity, 3, reason: 'sent as typed');
    expect(draft.unitCode, 'carton', reason: 'the server converts, once');
  });

  testWidgets('an item that comes in ones shows no unit strip at all', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('تعدّ بـ'), findsNothing);
  });

  testWidgets('Enter on a number that is not a number says so', (tester) async {
    final harness = await _pump(tester);

    await tester.enterText(_searchField, 'CHP');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.enterText(_quantityField, '1.2.3');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(harness.stockCounts.drafts, isEmpty);
    expect(find.text('أدخل كمية صحيحة قبل الحفظ.'), findsOneWidget);
    expect(_quantityField, findsOneWidget, reason: 'the item stays in hand');
  });

  testWidgets('a row this counter already did says so, with their number', (
    tester,
  ) async {
    await _pump(
      tester,
      session: _session(
        lines: [
          const StockCountLine(
            id: 1,
            stockCountId: 1,
            variantId: 5,
            countedQuantity: 12,
            expectedQuantity: 12,
            variance: 0,
            needsReview: false,
            applied: false,
            staleAtApply: false,
          ),
        ],
      ),
    );

    expect(find.text('عددت 12'), findsOneWidget);
  });
}

class _FakeStockCountRepository extends StockCountRepository {
  _FakeStockCountRepository({this.systemQuantity}) : super(PosApiService());

  /// What the system believes is on the shelf. Null agrees with every count;
  /// set, a count that differs comes back flagged, as the server flags it.
  final double? systemQuantity;

  final List<StockCountLineDraft> drafts = [];

  @override
  Future<Result<StockCountLine>> recordLine(
    int countId,
    StockCountLineDraft draft,
  ) async {
    drafts.add(draft);
    final expected = systemQuantity ?? draft.countedQuantity;
    return Ok(
      StockCountLine(
        id: drafts.length,
        stockCountId: countId,
        variantId: draft.variantId,
        countedQuantity: draft.countedQuantity,
        expectedQuantity: expected,
        variance: draft.countedQuantity - expected,
        needsReview: draft.countedQuantity != expected,
        applied: false,
        staleAtApply: false,
      ),
    );
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this.variants) : super(PosApiService());

  final List<ProductVariant> variants;
  final List<ProductQuery> queries = [];

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    queries.add(query);
    final term = query.search.trim().toLowerCase();
    final matches = term.isEmpty
        ? variants
        : variants
              .where(
                (variant) =>
                    variant.displayLabel.toLowerCase().contains(term) ||
                    variant.sku.toLowerCase().contains(term),
              )
              .toList(growable: false);
    return Ok(
      ProductVariantPage(
        variants: page == 1 ? matches : const [],
        hasMore: false,
      ),
    );
  }
}
