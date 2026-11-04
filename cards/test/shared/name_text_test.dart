import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/name_text.dart';

void main() {
  test('a name reads in the direction of its first letter', () {
    expect(NameText.directionOf('7 Days to Die'), TextDirection.ltr);
    expect(NameText.directionOf('Battlefield 4™'), TextDirection.ltr);
    expect(NameText.directionOf('ليبيانا · 10 دينار'), TextDirection.rtl);
    expect(NameText.directionOf('«ستيم»'), TextDirection.rtl);
    expect(NameText.directionOf('10 · 20'), isNull);
  });

  testWidgets('a Latin title keeps its order on an Arabic page', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          children: [NameText('7 Days to Die'), NameText('ليبيانا')],
        ),
      ),
    );
    final latin = tester.widget<Text>(find.text('7 Days to Die'));
    expect(latin.textDirection, TextDirection.ltr);
    // Still against the Arabic page's start edge.
    expect(latin.textAlign, TextAlign.right);
    expect(
      tester.widget<Text>(find.text('ليبيانا')).textDirection,
      TextDirection.rtl,
    );
  });
}
