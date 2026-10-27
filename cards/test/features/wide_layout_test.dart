import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/legal/legal_document.dart';
import 'package:pointy_cards/src/features/legal/legal_page.dart';
import 'package:pointy_cards/src/features/legal/licenses_page.dart';
import 'package:pointy_cards/src/features/shell/cards_sidebar.dart';
import 'package:pointy_cards/src/shared/card_art.dart';

/// The iPhone Duo, closed and open: a system column down the right edge.
const closed = Size(466, 678);
const open = Size(951, 669);

void duo(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(right: 100 * 3);
  addTearDown(tester.view.reset);
}

CardBrand brandAt(int index) => CardBrand.fromJson(
  (fixtureCatalog['brands'] as List)[index] as Map<String, dynamic>,
);

void main() {
  for (final (name, size) in [('closed', closed), ('open', open)]) {
    testWidgets('every tab fits the iPhone Duo $name', (tester) async {
      duo(tester, size);
      await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
      await tester.pumpAndSettle();
      for (final tab in ['كروتي', 'حسابي', 'الرئيسية']) {
        await tester.tap(find.byTooltip(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });

    testWidgets('the brand page keeps clear of the column ($name)', (
      tester,
    ) async {
      duo(tester, size);
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(),
          home: BrandPage(brand: brandAt(3)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final title = tester.getRect(find.text('ببجي موبايل').last);
      expect(title.right, lessThanOrEqualTo(size.width - 100));
    });
  }

  testWidgets('open, the card stands beside its details', (tester) async {
    duo(tester, open);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: BrandPage(brand: brandAt(3)),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(CardArt).first);
    final choose = tester.getRect(find.text('اختر الفئة'));
    // Right to left: the card on the right, the details on the left, level.
    expect(card.left, greaterThan(choose.right));
    expect(card.top, lessThan(choose.bottom + 200));
    expect(find.text('اشترِ'), findsOneWidget);
  });

  testWidgets('back sits in the column, and titles stay clear of it', (
    tester,
  ) async {
    duo(tester, open);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: const LegalPage(document: LegalDocument.privacy),
      ),
    );
    await tester.pumpAndSettle();
    final back = tester.getRect(find.byType(BackButtonIcon).last);
    expect(back.left, greaterThanOrEqualTo(open.width - 100));
    expect(back.top, greaterThan(90));
    final titles = find.text('سياسة الخصوصية', skipOffstage: false);
    for (var i = 0; i < titles.evaluate().length; i++) {
      final rect = tester.getRect(titles.at(i));
      expect(rect.right, lessThanOrEqualTo(open.width - 100));
    }
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('the licenses: a list in our style, each one as written', (
    tester,
  ) async {
    duo(tester, open);
    final packages = Future.value([
      LicensedPackage('abseil-cpp', [
        const LicenseEntryWithLineBreaks([
          'abseil-cpp',
        ], 'Apache License\n\nTERMS'),
      ]),
      LicensedPackage('http', [
        const LicenseEntryWithLineBreaks(['http'], 'BSD'),
        const LicenseEntryWithLineBreaks(['http'], 'MIT'),
      ]),
    ]);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: LicensesPage(packages: packages),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('abseil-cpp'), findsOneWidget);
    expect(find.text('http'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();
    expect(find.text('BSD'), findsOneWidget);
    expect(find.text('MIT'), findsOneWidget);
    final body = tester.getRect(find.text('BSD'));
    expect(body.right, lessThanOrEqualTo(open.width - 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reading pages: the title and the text share one middle', (
    tester,
  ) async {
    duo(tester, open);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: LicensesPage(
          packages: Future.value([
            LicensedPackage('http', [
              const LicenseEntryWithLineBreaks(['http'], 'BSD'),
            ]),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final titles = find.text('تراخيص البرامج مفتوحة المصدر');
    final title = tester.getRect(titles.last);
    final list = tester.getRect(find.byType(ListTile));
    expect(title.center.dx, closeTo(list.center.dx, 1));
    // The page's middle: between the screen's edge and the column.
    expect(list.center.dx, closeTo((open.width - 100) / 2, 1));

    // Opened from another page, still only the column's back button.
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsNothing);
    expect(find.byType(BackButtonIcon), findsOneWidget);
  });

  testWidgets('closed, the back button clears the camera and the status', (
    tester,
  ) async {
    duo(tester, closed);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: const LegalPage(document: LegalDocument.terms),
      ),
    );
    await tester.pumpAndSettle();
    final back = tester.getRect(find.byType(BackButtonIcon).last);
    // The time and the signal end 150 points down when closed.
    expect(back.top, greaterThan(150));
    // On the status items' centre line, 48 points in from the edge.
    expect(back.center.dx, closeTo(closed.width - 48, 1));
  });

  testWidgets('a desktop window: a sidebar instead of the tab bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    expect(find.byType(CardsSidebar), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    // Its categories show the shelf on one, named in the title.
    await tester.tap(
      find.descendant(
        of: find.byType(CardsSidebar),
        matching: find.text('الألعاب'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('الألعاب'), findsNWidgets(2));
    // And its places are the tabs.
    await tester.tap(find.text('حسابي'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
