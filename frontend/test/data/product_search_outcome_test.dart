import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_search_outcome.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_search_outcome_line.dart';

void main() {
  test('a page carries how its search was found', () {
    final page = ProductPage.fromJson({
      'next': null,
      'results': <Object?>[],
      'search': {
        'query': 'عصبر',
        'match': 'corrected',
        'corrected_query': 'عصير',
        'hidden_out_of_stock': 0,
        'category_fallback': true,
      },
    });

    final outcome = page.searchOutcome!;
    expect(outcome.match, ProductSearchMatch.corrected);
    expect(outcome.correctedQuery, 'عصير');
    expect(outcome.categoryFallback, isTrue);
    expect(outcome.isApproximate, isTrue);
  });

  test('a page from a server that predates it carries none', () {
    final page = ProductPage.fromJson({'next': null, 'results': <Object?>[]});

    expect(page.searchOutcome, isNull);
  });

  test('an unknown match reads as exact rather than failing', () {
    expect(
      ProductSearchOutcome.fromJson({'match': 'telepathy'})!.match,
      ProductSearchMatch.exact,
    );
  });

  group('what the till says about it', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    });

    test('a corrected search names what was searched instead', () {
      final message = posSearchOutcomeMessage(
        l10n,
        const ProductSearchOutcome(
          match: ProductSearchMatch.corrected,
          correctedQuery: 'عصير',
        ),
      );
      expect(message, contains('عصير'));
    });

    test('results from other categories say so', () {
      expect(
        posSearchOutcomeMessage(
          l10n,
          const ProductSearchOutcome(
            match: ProductSearchMatch.exact,
            categoryFallback: true,
          ),
        ),
        l10n.posSearchOtherCategoriesNotice,
      );
    });

    test('a search found as typed says nothing', () {
      expect(
        posSearchOutcomeMessage(
          l10n,
          const ProductSearchOutcome(match: ProductSearchMatch.exact),
        ),
        isNull,
      );
    });
  });
}
