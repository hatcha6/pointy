import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/learning/content/learning_library.dart';
import 'package:pointy_frontend/src/features/learning/search/learning_search.dart';

/// The search box is the whole navigation model of this module — a cashier
/// mid-shift types a word, not a track name. These cover the Arabic spellings
/// people actually produce, which a plain `contains` would miss entirely.
void main() {
  group('normalization', () {
    test('folds the alef family', () {
      expect(normalizeSearchText('آجل'), normalizeSearchText('اجل'));
      expect(normalizeSearchText('الإستلام'), normalizeSearchText('الاستلام'));
      expect(normalizeSearchText('أمر'), normalizeSearchText('امر'));
    });

    test('folds ta marbuta, alef maqsura and hamza carriers', () {
      expect(normalizeSearchText('فاتورة'), normalizeSearchText('فاتوره'));
      expect(normalizeSearchText('على'), normalizeSearchText('علي'));
      expect(normalizeSearchText('دفعة مقدّمة'), 'دفعه مقدمه');
    });

    test('strips tashkeel and tatweel', () {
      expect(normalizeSearchText('مُقدَّمة'), normalizeSearchText('مقدمة'));
      expect(normalizeSearchText('اســـتلام'), normalizeSearchText('استلام'));
    });

    test('converts Arabic-Indic digits and lowercases latin', () {
      expect(normalizeSearchText('٥٨'), '58');
      expect(normalizeSearchText('POS'), 'pos');
    });

    test('collapses punctuation into token breaks', () {
      expect(normalizeSearchText('«الدفع»، والتقسيم!'), 'الدفع والتقسيم');
    });
  });

  group('tokenization', () {
    test('drops the definite article so both spellings search alike', () {
      expect(
        tokenizeSearchText(normalizeSearchText('الفاتورة')),
        tokenizeSearchText(normalizeSearchText('فاتورة')),
      );
    });

    test('keeps short words that merely start with alef-lam', () {
      // "ألم" is three letters; stripping "ال" would leave a single letter and
      // match almost everything.
      expect(tokenizeSearchText(normalizeSearchText('الم')), ['الم']);
    });
  });

  group('scoring', () {
    List<String> tokensFor(String query) =>
        tokenizeSearchText(normalizeSearchText(query));

    int scoreOf(String guideId, String query) =>
        learningSearchIndexes[guideId]!.score(tokensFor(query));

    test('a title match outranks a passing mention in the body', () {
      final splitTender = scoreOf('money.split_tender', 'تقسيم الدفع');
      final mention = scoreOf('selling.first_sale', 'تقسيم الدفع');
      expect(splitTender, greaterThan(0));
      expect(splitTender, greaterThan(mention));
    });

    test('every query token must match (AND, not OR)', () {
      expect(scoreOf('money.split_tender', 'تقسيم زرافة'), 0);
    });

    test('a prefix matches mid-typing', () {
      expect(scoreOf('purchasing.create_po', 'مشتر'), greaterThan(0));
    });

    test('latin keywords reach the Arabic guides', () {
      expect(scoreOf('setup.remote_access', 'remote'), greaterThan(0));
      expect(scoreOf('catalog.variants_concept', 'variants'), greaterThan(0));
    });

    test('an unspelled query still finds its guide', () {
      // What a cashier types: no hamza, no tashkeel.
      expect(scoreOf('money.credit_sale', 'اجل'), greaterThan(0));
      expect(
        scoreOf('money.credit_down_payment', 'دفعه مقدمه'),
        greaterThan(0),
      );
    });

    test('the best result for a real question is the right guide', () {
      for (final (query, expectedId) in const [
        ('تقسيم الدفع', 'money.split_tender'),
        ('دفعة مقدمة', 'money.credit_down_payment'),
        ('أمر شراء', 'purchasing.lifecycle'),
        ('الوصول عن بعد', 'setup.remote_access'),
        ('اختصارات', 'selling.shortcuts'),
      ]) {
        final tokens = tokensFor(query);
        final ranked =
            learningLibrary
                .map(
                  (guide) => (
                    guide.id,
                    learningSearchIndexes[guide.id]!.score(tokens),
                  ),
                )
                .where((entry) => entry.$2 > 0)
                .toList()
              ..sort((a, b) => b.$2.compareTo(a.$2));
        expect(ranked, isNotEmpty, reason: query);
        expect(ranked.first.$1, expectedId, reason: query);
      }
    });
  });
}
