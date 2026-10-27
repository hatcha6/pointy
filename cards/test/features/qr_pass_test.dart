import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/features/reveal/card_faces.dart';
import 'package:pointy_cards/src/features/reveal/qr_pass.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'feel_test.dart' show phone;

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
    expect(find.byType(QrCardFace), findsNothing);

    await tester.tap(find.byIcon(Icons.qr_code_2_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(QrCardFace), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('امسحه بالكاميرا لقراءة الرقم السري'), findsOneWidget);
    expect(calls, ['up']);

    await tester.tap(find.byTooltip('إغلاق').last);
    await tester.pumpAndSettle();
    expect(find.byType(QrCardFace), findsNothing);
    expect(calls, ['up', 'down']);
    // The card it lifted out of is back on the page.
    expect(find.byType(CodeCardFace), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
