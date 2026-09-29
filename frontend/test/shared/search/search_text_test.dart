import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/search/search_text.dart';

void main() {
  group('foldSearchText agrees with the backend fold', () {
    // Every expected value below is what `apps/catalog/search_text.fold`
    // returns for the same input, so a list filtered on the device and a
    // search answered by the server read text the same way.
    const cases = <String, String>{
      'كاتشب575': 'كاتشب 575',
      'أرز  مصري': 'ارز مصري',
      "Kellogg's": 'kelloggs',
      'حليب 1.5 لتر': 'حليب 1.5 لتر',
      'علبة 1/4': 'علبه 1/4',
      'سكر، ملح': 'سكر ملح',
      'قهوة-تركية': 'قهوه تركيه',
      '٥٧٥ جرام': '575 جرام',
      'مُعَلَّبَات': 'معلبات',
      'ـــشاي': 'شاي',
      'a.b': 'a b',
      '1.': '1',
      '.5': '5',
      '5x5': '5 x 5',
      'x\u{200F}y': 'xy',
      '(كبير)': 'كبير',
      'وزن:2كغ': 'وزن 2 كغ',
      '٣٫٥': '3.5',
      '1,000': '1,000',
      'A1B2': 'a 1 b 2',
      'الإعدادات': 'الاعدادات',
      'ى ئ ی ؤ ة ۀ ک': 'ي ي ي و ه ه ك',
      '٪5': '5',
      'ab_cd': 'ab cd',
      'a\tb\nc': 'a b c',
    };
    for (final MapEntry(key: input, value: expected) in cases.entries) {
      test('«$input»', () {
        expect(foldSearchText(input), expected);
      });
    }
  });

  test('folds every alef, yeh, waw and heh variant', () {
    expect(foldSearchText('أإآٱ'), 'اااا');
    expect(foldSearchText('ىئی'), 'ييي');
    expect(foldSearchText('ؤ'), 'و');
    expect(foldSearchText('ةۀ'), 'هه');
    expect(foldSearchText('ک'), 'ك');
  });

  test('makes both Arabic digit sets ASCII', () {
    expect(foldSearchText('٠١٢٣٤٥٦٧٨٩'), '0123456789');
    expect(foldSearchText('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
  });

  test('drops marks, tatweel, direction controls and apostrophes', () {
    expect(foldSearchText('شَايٌ'), 'شاي');
    expect(foldSearchText('ٱلرَّحْمٰنِ'), 'الرحمن');
    expect(foldSearchText('ؐقهوة'), 'قهوه');
    expect(foldSearchText('\u{2066}abc\u{2069}\u{FEFF}'), 'abc');
    expect(foldSearchText('\u{202B}شاي\u{202C}'), 'شاي');
    expect(foldSearchText('\u{200B}زيت'), 'زيت');
    // The acute accent (´) is left out: the backend's NFKC turns it into a
    // space and a combining mark before its own drop step can see it.
    expect(foldSearchText('o’neil ‘x’ `y`'), 'oneil x y');
  });

  test('turns punctuation into spaces', () {
    expect(foldSearchText('شاي!؟ «أخضر»'), 'شاي اخضر');
    expect(foldSearchText('a*b+c=d'), 'a b c d');
    expect(foldSearchText('سكر؛ ملح… زيت'), 'سكر ملح زيت');
    expect(foldSearchText('x–y—z•w·v'), 'x y z w v');
  });

  test('keeps the separators inside a number and nowhere else', () {
    expect(foldSearchText('4.75'), '4.75');
    expect(foldSearchText('1/4'), '1/4');
    expect(foldSearchText('1..5'), '1 5');
    expect(foldSearchText('كيلو/جرام'), 'كيلو جرام');
    expect(foldSearchText('1.5كغ'), '1.5 كغ');
  });

  test('folds the lam-alef ligatures the way NFKC would', () {
    expect(foldSearchText('ﻻ'), 'لا');
    expect(foldSearchText('ﻷ'), 'لا');
    expect(foldSearchText('ﻹ'), 'لا');
    expect(foldSearchText('ﻵ'), 'لا');
  });

  test('lower-cases Latin text', () {
    expect(foldSearchText('PEPSI Max'), 'pepsi max');
  });

  test('blank in, blank out', () {
    expect(foldSearchText(''), '');
    expect(foldSearchText('   '), '');
    expect(foldSearchText('ـــ'), '');
    expect(foldSearchText('?!'), '');
  });

  group('searchTokens', () {
    test('splits the folded text into words, in order', () {
      expect(searchTokens('كاتشب575'), ['كاتشب', '575']);
      expect(searchTokens('حليب 1.5 لتر'), ['حليب', '1.5', 'لتر']);
    });

    test('drops repeats', () {
      expect(searchTokens('ى ئ ی ؤ ة ۀ ک'), ['ي', 'و', 'ه', 'ك']);
      expect(searchTokens('أرز ارز'), ['ارز']);
    });

    test('has no words for text that folds away', () {
      expect(searchTokens(''), isEmpty);
      expect(searchTokens(' - ؟ '), isEmpty);
    });
  });
}
