import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';

/// A new product's SKU is the shop's next number — 1000, 1001, 1002 — and the
/// form shows it before saving, so the owner sees the code the product will
/// carry and can make the barcode the same code in one click.
void main() {
  const colourOption = {
    'id': 1,
    'code': 'color',
    'name': 'اللون',
    'display_order': 1,
    'is_active': true,
    'values': [
      {'id': 11, 'option': 1, 'code': 'red', 'name': 'أحمر', 'is_active': true},
      {
        'id': 12,
        'option': 1,
        'code': 'blue',
        'name': 'أزرق',
        'is_active': true,
      },
    ],
  };

  /// What the server answered and was sent. [nextSkus] is served in order,
  /// the last one repeating — so a test can have a number "taken" between the
  /// form opening and the save.
  ({PosApiService service, List<Map<String, Object?>> posted}) buildService({
    required List<String> nextSkus,
  }) {
    final posted = <Map<String, Object?>>[];
    var nextSkuCalls = 0;
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
          final index = nextSkuCalls < nextSkus.length
              ? nextSkuCalls
              : nextSkus.length - 1;
          nextSkuCalls += 1;
          return json({'sku': nextSkus[index]});
        }
        if (path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (path.contains('variant-options')) {
          return json(const {
            'results': [colourOption],
            'next': null,
          });
        }
        if (request.method == 'POST') {
          posted.add(jsonDecode(request.body) as Map<String, Object?>);
          return json(const {'id': 12, 'name': 'أرز', 'variants': []}, 201);
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    return (service: service, posted: posted);
  }

  Future<List<Map<String, Object?>>> pumpForm(
    WidgetTester tester, {
    required List<String> nextSkus,
    String? initialBarcode,
  }) async {
    final built = buildService(nextSkus: nextSkus);
    final viewModel = CatalogViewModel(CatalogRepository(built.service));
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductForm(
            viewModel: viewModel,
            initialBarcode: initialBarcode,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return built.posted;
  }

  Future<void> goToVariantStep(
    WidgetTester tester,
    AppLocalizations l10n,
  ) async {
    await tester.enterText(find.byType(TextFormField).first, 'أرز');
    await tester.tap(find.text(l10n.nextButton));
    await tester.pumpAndSettle();
  }

  // Step two, in order: variant name, SKU, barcode, price.
  String fieldText(WidgetTester tester, int index) => tester
      .widget<TextFormField>(find.byType(TextFormField).at(index))
      .controller!
      .text;

  Future<Map<String, Object?>> create(
    WidgetTester tester,
    AppLocalizations l10n,
    List<Map<String, Object?>> posted,
  ) async {
    await tester.enterText(find.byType(TextFormField).at(3), '5');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.createProductButton));
    await tester.pumpAndSettle();
    expect(posted, hasLength(1));
    return posted.single['default_variant']! as Map<String, Object?>;
  }

  testWidgets('a new product shows the SKU it will be saved with', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final posted = await pumpForm(tester, nextSkus: ['1042']);
    await goToVariantStep(tester, l10n);

    expect(fieldText(tester, 1), '1042');
    expect(find.text(l10n.skuAutomaticHelper), findsOneWidget);

    final sent = await create(tester, l10n, posted);
    expect(sent['sku'], '1042');
    expect(sent['barcode'], '');
  });

  testWidgets('one click makes the barcode the SKU', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final posted = await pumpForm(tester, nextSkus: ['1042']);
    await goToVariantStep(tester, l10n);

    await tester.tap(find.byTooltip(l10n.useSkuAsBarcodeTooltip));
    await tester.pump();

    expect(fieldText(tester, 2), '1042');
    final sent = await create(tester, l10n, posted);
    expect(sent['sku'], '1042');
    expect(sent['barcode'], '1042');
  });

  testWidgets('the copy takes whatever SKU the owner typed instead', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(tester, nextSkus: ['1042']);
    await goToVariantStep(tester, l10n);

    await tester.enterText(find.byType(TextFormField).at(1), 'rice-5');
    await tester.tap(find.byTooltip(l10n.useSkuAsBarcodeTooltip));
    await tester.pump();

    // Upper-cased, the way the server stores the SKU it is copied from.
    expect(fieldText(tester, 2), 'RICE-5');
  });

  testWidgets(
    'a number another till took meanwhile moves on, the copied barcode with it',
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      // 1042 when the form opened; by the time it is saved, 1042 is gone.
      final posted = await pumpForm(tester, nextSkus: ['1042', '1043']);
      await goToVariantStep(tester, l10n);
      await tester.tap(find.byTooltip(l10n.useSkuAsBarcodeTooltip));
      await tester.pump();

      final sent = await create(tester, l10n, posted);

      expect(sent['sku'], '1043');
      expect(sent['barcode'], '1043');
    },
  );

  testWidgets('a SKU the owner typed is never renumbered', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final posted = await pumpForm(tester, nextSkus: ['1042', '1043']);
    await goToVariantStep(tester, l10n);

    await tester.enterText(find.byType(TextFormField).at(1), 'RICE-5');
    final sent = await create(tester, l10n, posted);

    expect(sent['sku'], 'RICE-5');
  });

  testWidgets("a scanner's Enter in the barcode field moves on to the price", (
    tester,
  ) async {
    // A scanner types the code and presses Enter. Landing on the copy button
    // instead would put the next keystroke there — and replace the scanned
    // code with the SKU.
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(tester, nextSkus: ['1042']);
    await goToVariantStep(tester, l10n);

    await tester.enterText(find.byType(TextFormField).at(2), '6281234567890');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    final price = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(TextFormField).at(3),
        matching: find.byType(EditableText),
      ),
    );
    expect(FocusManager.instance.primaryFocus, price.focusNode);
    expect(fieldText(tester, 2), '6281234567890');
  });

  testWidgets('a scanned product keeps its barcode and gets the next number', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final posted = await pumpForm(
      tester,
      nextSkus: ['1042'],
      initialBarcode: '6281234567890',
    );
    await goToVariantStep(tester, l10n);

    expect(fieldText(tester, 1), '1042');
    expect(fieldText(tester, 2), '6281234567890');
    final sent = await create(tester, l10n, posted);
    expect(sent['sku'], '1042');
    expect(sent['barcode'], '6281234567890');
  });

  testWidgets('each generated variant gets a number of its own', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final posted = await pumpForm(tester, nextSkus: ['1042']);

    Future<void> tapVisible(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tester.enterText(find.byType(TextFormField).first, 'قميص');
    await tester.pumpAndSettle();
    await tapVisible(find.byKey(const ValueKey('variant_option_search_field')));
    await tapVisible(find.text('اللون'));
    await tapVisible(find.text(l10n.nextButton));
    await tapVisible(find.text(l10n.selectAllVariantOptionValues(2)));
    await tester.enterText(
      find.widgetWithText(TextFormField, l10n.generatedVariantPriceLabel),
      '20',
    );
    await tester.pumpAndSettle();

    await tapVisible(find.text(l10n.createProductButton));

    final variants = (posted.single['variants']! as List)
        .cast<Map<String, Object?>>();
    expect([for (final variant in variants) variant['sku']], ['1042', '1043']);
  });

  testWidgets('opening and closing the form does not count as unsaved work', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final built = buildService(nextSkus: ['1042']);
    final viewModel = CatalogViewModel(CatalogRepository(built.service));
    addTearDown(viewModel.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: ProductForm(viewModel: viewModel)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
    expect(find.byType(ProductForm), findsNothing);
  });
}
