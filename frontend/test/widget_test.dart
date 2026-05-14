import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pointy_frontend/src/app.dart';

void main() {
  testWidgets('POS shell renders and accepts cart input', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('نقطة البيع'), findsOneWidget);
    expect(find.text('البيع الحالي'), findsOneWidget);

    await tester.tap(find.text('قهوة البيت'));
    await tester.pump();

    expect(find.text('ادفع د.ل 3.78'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });
}
