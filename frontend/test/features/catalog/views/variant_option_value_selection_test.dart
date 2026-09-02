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

/// Adding an option used to select every value it carried, so one tap on
/// "colour" plus one on "size" generated a couple of hundred variant forms the
/// shop never asked for. Values are chosen deliberately now, with a one-tap
/// escape hatch for the shop that really does carry every size.
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
      {
        'id': 13,
        'option': 1,
        'code': 'green',
        'name': 'أخضر',
        'is_active': true,
      },
    ],
  };

  Future<AppLocalizations> pumpForm(WidgetTester tester) async {
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final body = request.url.path.contains('variant-options')
            ? {
                'results': const [colourOption],
                'next': null,
              }
            : {'results': const <Object?>[], 'next': null};
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final viewModel = CatalogViewModel(CatalogRepository(service));
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ProductForm(viewModel: viewModel)),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  /// The form is taller than the test viewport, so anything below the fold has
  /// to be scrolled to before it can be tapped.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Names the product, adds the colour option from the search menu, and moves
  /// on to the step where its values are chosen.
  Future<void> addColourAndAdvance(
    WidgetTester tester,
    AppLocalizations l10n,
  ) async {
    // enterText round-trips through the platform text input, so the form has
    // to settle before the next tap lands on the layout it produced.
    await tester.enterText(find.byType(TextFormField).first, 'قميص');
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.byKey(const ValueKey('variant_option_search_field')),
    );
    await tapVisible(tester, find.text('اللون'));
    await tapVisible(tester, find.text(l10n.nextButton));
  }

  testWidgets('adding an option selects none of its values', (tester) async {
    final l10n = await pumpForm(tester);
    await addColourAndAdvance(tester, l10n);

    expect(find.text(l10n.variantOptionNoValuesSelected), findsOneWidget);
    expect(find.text(l10n.generatedVariantsEmpty), findsOneWidget);
    for (final name in ['أحمر', 'أزرق', 'أخضر']) {
      expect(
        find.widgetWithText(InputChip, name),
        findsNothing,
        reason: '$name was not chosen',
      );
    }
  });

  testWidgets('every remaining value can still be added in one tap', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await addColourAndAdvance(tester, l10n);

    await tapVisible(tester, find.text(l10n.selectAllVariantOptionValues(3)));

    for (final name in ['أحمر', 'أزرق', 'أخضر']) {
      expect(find.widgetWithText(InputChip, name), findsOneWidget);
    }
    expect(find.text(l10n.variantOptionSelectedValuesCount(3)), findsOneWidget);
    expect(find.text(l10n.generatedVariantsCount(3)), findsOneWidget);
    // Nothing is left to add, so the shortcut retires.
    expect(find.text(l10n.selectAllVariantOptionValues(0)), findsNothing);
  });
}
