import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_entry_pins.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';

/// A shop on a fresh install types in its whole catalogue by hand, product
/// after product. «إنشاء وإضافة آخر» keeps the panel open and starts the next
/// product; the fields the owner pins carry over and say so, codes and the
/// shelf count never do, and the whole loop runs from the keyboard.
void main() {
  const addAnotherButton = ValueKey('product_form_add_another_button');
  late List<Map<String, Object?>> posted;
  late List<Product> closedWith;
  late List<Product> opened;

  CatalogViewModel buildViewModel() {
    var nextSku = 1042;
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/next-sku/')) {
          return json({'sku': '$nextSku'});
        }
        if (path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (request.method == 'POST' && path.endsWith('/products/')) {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          posted.add(body);
          final id = 100 + posted.length;
          final sku = '$nextSku';
          nextSku += 1;
          return json({
            'id': id,
            'name': body['name'],
            'variants': [
              {
                'id': id * 10,
                'product': id,
                'sku': sku,
                'barcode': '',
                'unit_price': '1.00',
                'is_default': true,
              },
            ],
          }, 201);
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = CatalogViewModel(CatalogRepository(service));
    addTearDown(viewModel.dispose);
    return viewModel;
  }

  Widget formFor(CatalogViewModel viewModel, {required bool offerAddAnother}) {
    return ProductForm(
      viewModel: viewModel,
      offerAddAnother: offerAddAnother,
      showOpeningStock: true,
      onCreated: closedWith.add,
      onOpenCreated: opened.add,
    );
  }

  Future<AppLocalizations> pumpForm(
    WidgetTester tester, {
    bool offerAddAnother = true,
  }) async {
    posted = [];
    closedWith = [];
    opened = [];
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: formFor(buildViewModel(), offerAddAnother: offerAddAnother),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  String textOf(WidgetTester tester, String label) =>
      tester.widget<TextFormField>(field(label)).controller!.text;

  FocusNode focusOf(WidgetTester tester, String label) => tester
      .widget<EditableText>(
        find.descendant(of: field(label), matching: find.byType(EditableText)),
      )
      .focusNode;

  Finder pinOf(String label) => find.descendant(
    of: find.ancestor(of: field(label), matching: find.byType(PinnableField)),
    matching: find.byType(IconButton),
  );

  BarcodeScanListener scanListener(WidgetTester tester) =>
      tester.widget<BarcodeScanListener>(
        find.descendant(
          of: find.byType(ProductForm),
          matching: find.byType(BarcodeScanListener),
        ),
      );

  Future<void> fill(
    WidgetTester tester,
    AppLocalizations l10n, {
    String? barcode,
    String? name,
    String? price,
  }) async {
    if (barcode != null) {
      await tester.enterText(field(l10n.barcodeLabel), barcode);
    }
    if (name != null) {
      await tester.enterText(field(l10n.productNameLabel), name);
    }
    if (price != null) {
      await tester.enterText(field(l10n.unitPriceLabel), price);
    }
    // The live duplicate-code check is debounced.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  Future<void> addAnother(WidgetTester tester, AppLocalizations l10n) async {
    await tester.tap(find.text(l10n.createAndAddAnotherButton));
    await tester.pumpAndSettle();
  }

  Future<void> tapPin(WidgetTester tester, String label) async {
    await tester.tap(pinOf(label));
    await tester.pumpAndSettle();
  }

  testWidgets('adding another keeps the panel open for the next product', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    expect(find.byType(FieldPinButton), findsNothing);

    await fill(
      tester,
      l10n,
      barcode: '6281000000013',
      name: 'كفر ايفون 13',
      price: '25',
    );
    await tester.enterText(field(l10n.openingStockQuantityLabel), '4');
    await addAnother(tester, l10n);

    expect(posted, hasLength(1));
    expect(posted.single['name'], 'كفر ايفون 13');
    expect(closedWith, isEmpty, reason: 'the panel stays open');
    expect(
      find.text(l10n.productEntryLastCreated('كفر ايفون 13')),
      findsOneWidget,
    );
    expect(find.text(l10n.productEntryCreatedCount(1)), findsOneWidget);
    expect(find.text(l10n.productEntryPinsHint), findsOneWidget);
    expect(find.byType(FieldPinButton), findsWidgets);

    // Codes belong to one product and a shelf is counted: never carried.
    expect(textOf(tester, l10n.barcodeLabel), '');
    expect(textOf(tester, l10n.skuLabel), '1043');
    expect(textOf(tester, l10n.openingStockQuantityLabel), '');
    // Name and price start unpinned, so the next product starts without them.
    expect(textOf(tester, l10n.productNameLabel), '');
    expect(textOf(tester, l10n.unitPriceLabel), '');
    // Ready for the next scan.
    expect(
      FocusManager.instance.primaryFocus,
      focusOf(tester, l10n.barcodeLabel),
    );
  });

  testWidgets('a pinned name comes back with the cursor at its end', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await fill(
      tester,
      l10n,
      barcode: '111111',
      name: 'كفر ايفون 13',
      price: '25',
    );
    await addAnother(tester, l10n);

    await tapPin(tester, l10n.productNameLabel);

    final name = tester
        .widget<TextFormField>(field(l10n.productNameLabel))
        .controller!;
    expect(name.text, 'كفر ايفون 13');
    // Ctrl+Backspace from here takes off the last word.
    expect(
      name.selection,
      const TextSelection.collapsed(offset: 'كفر ايفون 13'.length),
    );
    expect(find.text(l10n.productNameUnchangedWarning), findsOneWidget);

    await fill(
      tester,
      l10n,
      barcode: '222222',
      name: 'كفر ايفون 14',
      price: '25',
    );
    expect(find.text(l10n.productNameUnchangedWarning), findsNothing);
    await addAnother(tester, l10n);

    expect(posted.map((body) => body['name']), [
      'كفر ايفون 13',
      'كفر ايفون 14',
    ]);
    // Still pinned, so the third product starts from the second's name.
    expect(textOf(tester, l10n.productNameLabel), 'كفر ايفون 14');
  });

  testWidgets('a pinned price carries on and is marked until it is changed', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await fill(
      tester,
      l10n,
      barcode: '111111',
      name: 'بيبسي علبة',
      price: '1.5',
    );
    await addAnother(tester, l10n);

    await tapPin(tester, l10n.unitPriceLabel);
    expect(textOf(tester, l10n.unitPriceLabel), '1.5');
    expect(find.text(l10n.productFieldKeptLabel), findsOneWidget);

    await fill(tester, l10n, barcode: '222222', name: 'ميرندا علبة');
    await addAnother(tester, l10n);

    final prices = [
      for (final body in posted)
        (body['default_variant']! as Map<String, Object?>)['unit_price'],
    ];
    expect(prices, ['1.50', '1.50']);
    expect(textOf(tester, l10n.unitPriceLabel), '1.5');
    expect(find.text(l10n.productFieldKeptLabel), findsOneWidget);

    await fill(tester, l10n, price: '2');
    expect(
      find.text(l10n.productFieldKeptLabel),
      findsNothing,
      reason: 'a price typed for this product is no longer the previous one',
    );
  });

  testWidgets('an unedited carried name asks once before it is saved', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await fill(tester, l10n, barcode: '111111', name: 'شاي', price: '5');
    await addAnother(tester, l10n);
    await tapPin(tester, l10n.productNameLabel);
    await fill(tester, l10n, barcode: '222222', price: '6');

    await addAnother(tester, l10n);
    expect(posted, hasLength(1), reason: 'two products named alike, unasked');
    expect(find.text(l10n.productNameUnchangedConfirm), findsOneWidget);

    // Focus landing back in the name moves its cursor; that is not an edit,
    // and must not take back the question just asked.
    tester
        .widget<TextFormField>(field(l10n.productNameLabel))
        .controller!
        .selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 3,
    );
    await tester.pump();
    expect(find.text(l10n.productNameUnchangedConfirm), findsOneWidget);

    await addAnother(tester, l10n);
    expect(posted, hasLength(2), reason: 'saving again means it was meant');
  });

  testWidgets('Enter walks the essential fields onto the add-another button', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);

    Future<void> enter() async {
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
    }

    await tester.showKeyboard(field(l10n.barcodeLabel));
    await enter();
    expect(
      FocusManager.instance.primaryFocus,
      focusOf(tester, l10n.productNameLabel),
    );
    await enter();
    expect(
      FocusManager.instance.primaryFocus,
      focusOf(tester, l10n.unitPriceLabel),
    );
    await enter();
    expect(
      FocusManager.instance.primaryFocus,
      focusOf(tester, l10n.openingStockQuantityLabel),
    );
    await enter();
    expect(
      FocusManager.instance.primaryFocus,
      focusOf(tester, l10n.openingStockUnitCostLabel),
    );
    await enter();
    expect(
      FocusManager.instance.primaryFocus,
      tester.widget<OutlinedButton>(find.byKey(addAnotherButton)).focusNode,
    );
  });

  testWidgets('Ctrl+Shift+Enter adds another; Ctrl+Enter creates and closes', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await fill(tester, l10n, name: 'أرز', price: '5');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(posted, hasLength(1));
    expect(closedWith, isEmpty);
    expect(find.text(l10n.productEntryCreatedCount(1)), findsOneWidget);

    await fill(tester, l10n, name: 'سكر', price: '4');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(posted, hasLength(2));
    expect(closedWith.single.name, 'سكر');
  });

  testWidgets('F7 pins and unpins the field that holds focus', (tester) async {
    final l10n = await pumpForm(tester);
    await fill(tester, l10n, barcode: '111111', name: 'زيت', price: '12');
    await addAnother(tester, l10n);

    await tester.showKeyboard(field(l10n.unitPriceLabel));
    await tester.sendKeyEvent(LogicalKeyboardKey.f7);
    await tester.pumpAndSettle();

    expect(textOf(tester, l10n.unitPriceLabel), '12');
    expect(
      tester.widget<IconButton>(pinOf(l10n.unitPriceLabel)).isSelected,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.f7);
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(pinOf(l10n.unitPriceLabel)).isSelected,
      isFalse,
    );
    // Unpinning only stops it going on to the next product.
    expect(textOf(tester, l10n.unitPriceLabel), '12');
  });

  testWidgets('a scan while typing elsewhere lands in the barcode', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await tester.enterText(field(l10n.productNameLabel), 'قهوة');
    await tester.enterText(field(l10n.unitPriceLabel), '12');
    await tester.pump();

    scanListener(tester).onBarcodeScanned('6281234567890');
    await tester.pump();

    expect(textOf(tester, l10n.barcodeLabel), '6281234567890');
    expect(textOf(tester, l10n.productNameLabel), 'قهوة');
    expect(textOf(tester, l10n.unitPriceLabel), '12');
    // Whoever was typing the price keeps their place.
    expect(
      FocusManager.instance.primaryFocus,
      focusOf(tester, l10n.unitPriceLabel),
    );
  });

  testWidgets('a scan into the barcode field moves on to the name', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await tester.showKeyboard(field(l10n.barcodeLabel));

    scanListener(tester).onBarcodeScanned('6281234567890');
    await tester.pump();

    expect(textOf(tester, l10n.barcodeLabel), '6281234567890');
    expect(
      FocusManager.instance.primaryFocus,
      focusOf(tester, l10n.productNameLabel),
    );
  });

  testWidgets("a scan's Enter does not press the button that has focus", (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await fill(tester, l10n, name: 'أرز', price: '5');
    VoidCallback press() =>
        tester.widget<OutlinedButton>(find.byKey(addAnotherButton)).onPressed!;

    // The listener consumes the scan, yet its Enter still reaches the focused
    // button within the same key event — before focus moves on to the name.
    scanListener(tester).onBarcodeScanned('6281234567890');
    press()();
    await tester.pumpAndSettle();

    expect(posted, isEmpty);
    expect(textOf(tester, l10n.barcodeLabel), '6281234567890');

    // A moment later the same press is somebody pressing the button.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    press()();
    await tester.pumpAndSettle();
    expect(posted, hasLength(1));
  });

  testWidgets('a carried unit is what the next product starts with', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await fill(tester, l10n, name: 'طماطم', price: '3');
    await tester.tap(find.text(l10n.unitPiece));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.unitKilogram).last);
    await tester.pumpAndSettle();

    await addAnother(tester, l10n);

    expect(posted.single['unit'], 'kg');
    // The unit is pinned from the start: a shelf of produce is sold by weight.
    expect(find.text(l10n.unitKilogram), findsOneWidget);
    expect(find.text(l10n.productFieldKeptLabel), findsOneWidget);
  });

  testWidgets('the product just created can be opened from the panel', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await fill(tester, l10n, name: 'عسل', price: '30');
    await addAnother(tester, l10n);

    await tester.tap(find.text(l10n.productEntryEditLastButton));
    await tester.pumpAndSettle();

    expect(opened.single.name, 'عسل');
  });

  testWidgets('a purchase order is not offered adding another', (tester) async {
    final l10n = await pumpForm(tester, offerAddAnother: false);

    expect(find.byKey(addAnotherButton), findsNothing);
    expect(find.text(l10n.createAndAddAnotherButton), findsNothing);
  });

  testWidgets('closing after a run asks nothing while the next is untouched', (
    tester,
  ) async {
    posted = [];
    closedWith = [];
    opened = [];
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final viewModel = buildViewModel();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(body: formFor(viewModel, offerAddAnother: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await fill(tester, l10n, name: 'طماطم', price: '3');
    await tester.tap(find.text(l10n.unitPiece));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.unitKilogram).last);
    await tester.pumpAndSettle();
    await addAnother(tester, l10n);

    // The carried unit is where the next product starts, not work to lose.
    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
    expect(find.byType(ProductForm), findsNothing);
  });
}
