import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/features/reveal/card_faces.dart';
import 'package:pointy_cards/src/features/reveal/card_qr.dart';
import 'package:pointy_cards/src/features/reveal/holo_foil.dart';
import 'package:pointy_cards/src/features/reveal/qr_pass.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';

import 'feel_test.dart' show phone;

/// Whether a card on screen is turning about its vertical axis: it narrows
/// edge-on without getting any shorter.
bool turned(WidgetTester tester) {
  for (final face in find.byType(CodeCardFace).evaluate()) {
    final box = face.findRenderObject()! as RenderBox;
    final transform = box.getTransformTo(null);
    if ((transform.getColumn(0).x / transform.getColumn(1).y - 1).abs() >
        0.001) {
      return true;
    }
  }
  return false;
}

void main() {
  testWidgets('the QR lifts the card out as a pass, bright, and sets it '
      'back', (tester) async {
    await phone(tester);
    final calls = <String>[];
    final before = QrPass.brightness;
    QrPass.brightness = (
      up: () async => calls.add('up'),
      down: () async => calls.add('down'),
    );
    addTearDown(() => QrPass.brightness = before);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: RevealPage(
          order: CardOrder.fromJson(fixtureOrder()),
          brand: CardBrand.fromJson(
            (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The QR waits under its foil.
    expect(find.byType(HoloFoil), findsOneWidget);
    expect(find.byType(CardQr), findsNothing);
    expect(calls, isEmpty);

    await tester.tap(find.byIcon(Icons.qr_code_2_rounded).last);
    // Every frame of the way up: the same back, never turned over.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(turned(tester), isFalse);
    }
    await tester.pumpAndSettle();
    // Scratched off, on the pass and on the page's card under it.
    expect(find.byType(HoloFoil), findsNothing);
    expect(find.byType(CardQr), findsNWidgets(2));
    expect(find.text('امسحه بالكاميرا لقراءة الرقم السري'), findsWidgets);
    expect(calls, ['up']);

    await tester.tap(find.byTooltip('إغلاق').last);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(turned(tester), isFalse);
    }
    await tester.pumpAndSettle();
    expect(calls, ['up', 'down']);
    // The card it lifted out of is back on the page, its foil still off.
    expect(find.byType(CodeCardFace), findsOneWidget);
    expect(find.byType(HoloFoil), findsNothing);
    expect(find.byType(CardQr), findsOneWidget);

    // The second time there is nothing left to scratch.
    await tester.tap(find.byType(CodeCardFace));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(HoloFoil), findsNothing);
    expect(find.byType(CardQr), findsNWidgets(2));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the card opens its pass, and fits, on the narrowest phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final before = QrPass.brightness;
    QrPass.brightness = (up: () async {}, down: () async {});
    addTearDown(() => QrPass.brightness = before);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: RevealPage(
          order: CardOrder.fromJson(fixtureOrder()),
          brand: CardBrand.fromJson(
            (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Tapping the card itself does what the QR button does.
    await tester.tap(find.byType(CodeCardFace));
    // An overflow on any frame fails the test.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(find.byType(CodeCardFace), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  group('the QR drawing', () {
    test('a clean hole for the mark, within what a scanner survives', () {
      for (final code in [
        '4827 1930 5561 2208',
        'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ12-3456',
      ]) {
        final grid = QrGrid.of(code)!;
        expect(grid.cleared.isOdd, isTrue);
        expect(
          grid.cleared * grid.cleared / (grid.modules * grid.modules),
          lessThan(0.08),
        );
        // The three finders are left whole.
        for (var row = 0; row < 7; row++) {
          expect(grid.isDark(row, 0), isTrue);
          expect(grid.isDark(row, grid.modules - 1), isTrue);
          expect(grid.isDark(grid.modules - 1 - row, 0), isTrue);
        }
      }
    });

    test('a finder is a ring around a square, not a solid block', () {
      // A scanner cannot find a code by solid corners.
      final path = QrGrid.of('4827 1930 5561 2208')!.toPath();
      expect(path.contains(const Offset(0.5, 3.5)), isTrue);
      expect(path.contains(const Offset(1.5, 3.5)), isFalse);
      expect(path.contains(const Offset(3.5, 3.5)), isTrue);
    });

    test('nothing to draw for a code too long for a QR', () {
      expect(QrGrid.of('x' * 2000), isNull);
    });
  });
}
