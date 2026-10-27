import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/support.dart';
import 'package:pointy_cards/src/features/legal/legal_document.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    // The bundle caches what it read, and a read begun under one test's
    // fake clock never finishes under the next one's.
    rootBundle.clear();
  });

  test('a legal file reads as headings, items and paragraphs', () {
    final blocks = LegalBlock.parse('''
آخر تحديث: اليوم

## العنوان
سطر أول
وسطر ثانٍ

- بند
- بند آخر

+218 92 001 0991
''');
    expect(
      [for (final block in blocks) block.kind],
      [
        LegalBlockKind.paragraph,
        LegalBlockKind.heading,
        LegalBlockKind.paragraph,
        LegalBlockKind.bullet,
        LegalBlockKind.bullet,
        LegalBlockKind.paragraph,
      ],
    );
    expect(blocks[2].text, 'سطر أول وسطر ثانٍ');
    expect(blocks[1].isLatin, isFalse);
    expect(blocks.last.isLatin, isTrue);
  });

  for (final document in LegalDocument.values) {
    test(
      'the ${document.name} text is complete, with nothing left to fill',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final text = await rootBundle.loadString(
          'assets/legal/${document.file}.ar.md',
        );
        final blocks = LegalBlock.parse(text);
        final headings = blocks.where((b) => b.kind == LegalBlockKind.heading);
        expect(headings.length, greaterThanOrEqualTo(8));
        expect(blocks.first.text, startsWith('آخر تحديث'));
        // Whoever reads it can reach us.
        expect(text, contains(Support.whatsAppDisplay));
        expect(
          RegExp(
            r'\[|\]|TODO|XXX|lorem|___|\.\.\.',
            caseSensitive: false,
          ).hasMatch(text),
          isFalse,
        );
        // An untranslated language falls back to the Arabic text.
        final fallback = await document.load('fr');
        expect(fallback.length, blocks.length);
      },
    );
  }

  Future<void> openAccount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final fixtures = fixtureDependencies(signedIn: false);
    await tester.pumpWidget(CardsApp(dependencies: fixtures));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حسابي').last);
    await tester.pumpAndSettle();
  }

  /// The texts are read from the asset bundle, real I/O the test's fake
  /// clock never waits for.
  Future<void> readAssets(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    // Clear the tab bar the page scrolls under.
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await readAssets(tester);
  }

  testWidgets('the account tab opens the privacy policy, terms and about', (
    tester,
  ) async {
    await openAccount(tester);
    await tester.scrollUntilVisible(
      find.text('حول التطبيق'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('حول التطبيق'), findsOneWidget);

    await tapRow(tester, 'سياسة الخصوصية');
    expect(find.text('ما نجمعه منك'), findsOneWidget);
    expect(find.text('سياسة الخصوصية'), findsWidgets);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tapRow(tester, 'شروط الاستخدام');
    expect(find.text('الخدمة'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tapRow(tester, 'حول دفتر كروت');
    expect(find.text('تواصل معنا عبر واتساب'), findsOneWidget);
    expect(find.text(Support.whatsAppDisplay), findsOneWidget);
    expect(find.text('تراخيص البرامج مفتوحة المصدر'), findsOneWidget);
  });

  testWidgets('signing in names the terms and privacy policy, as links', (
    tester,
  ) async {
    await openAccount(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
    await tester.pumpAndSettle();
    final consent = find.textContaining('بالمتابعة، أنت توافق على');
    expect(consent, findsOneWidget);
    await tester.tapOnText(
      find.textRange.ofSubstring('شروط الاستخدام', descendentOf: consent),
    );
    await readAssets(tester);
    expect(find.text('الخدمة'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tapOnText(
      find.textRange.ofSubstring('سياسة الخصوصية', descendentOf: consent),
    );
    await readAssets(tester);
    expect(find.text('ما نجمعه منك'), findsOneWidget);
  });
}
