import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';

/// The totals panel states figures, and — since the till's invoice discount
/// arrived — one of its lines is also the control for the figure it states.
///
/// The reporting lines must be untouched by that: they are on every invoice,
/// receipt preview and quote in the app, and a stray press target on the grand
/// total would be a way to change a sale by mis-tapping it.
void main() {
  Future<void> pump(WidgetTester tester, List<PointyTotalLine> lines) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Scaffold(
          body: SizedBox(width: 420, child: PointyTotalsPanel(lines: lines)),
        ),
      ),
    );
  }

  testWidgets('a reporting line has no press target', (tester) async {
    await pump(tester, const [
      PointyTotalLine(label: 'المجموع الفرعي', value: '15.00'),
      PointyTotalLine(label: 'الإجمالي', value: '15.00', isStrong: true),
    ]);

    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a line with an action is pressable and reports the press', (
    tester,
  ) async {
    var presses = 0;
    await pump(tester, [
      const PointyTotalLine(label: 'المجموع الفرعي', value: '15.00'),
      PointyTotalLine(
        label: 'خصم على الفاتورة',
        value: '-3.00',
        isMuted: true,
        actionIcon: Icons.discount_outlined,
        onTap: () => presses += 1,
      ),
      const PointyTotalLine(label: 'الإجمالي', value: '12.00', isStrong: true),
    ]);

    expect(find.byIcon(Icons.discount_outlined), findsOneWidget);
    await tester.tap(find.text('خصم على الفاتورة'));
    await tester.pump();

    expect(presses, 1);
  });

  testWidgets('a disabled action line renders without throwing', (
    tester,
  ) async {
    // An empty cart passes a null onTap: the row still has to draw, because it
    // is what the cashier presses once there is something to discount.
    await pump(tester, const [
      PointyTotalLine(
        label: 'إضافة خصم',
        value: '',
        isMuted: true,
        actionIcon: Icons.discount_outlined,
      ),
    ]);

    expect(find.byType(InkWell), findsNothing);
    expect(find.byIcon(Icons.discount_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the panel lays out inside a narrow till pane', (tester) async {
    // 320 logical pixels: the phone-width till. A long rule name next to a
    // money figure is where this panel overflows if it ever does.
    await tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: PointyTotalsPanel(
              compact: true,
              lines: [
                const PointyTotalLine(label: 'المجموع الفرعي', value: '15.00'),
                PointyTotalLine(
                  label: 'خصم ترحيبي على كل المشتريات لعملاء الجملة',
                  value: '-1.00',
                  isMuted: true,
                ),
                PointyTotalLine(
                  label: 'خصم على الفاتورة',
                  value: '-3.00',
                  isMuted: true,
                  actionIcon: Icons.discount_outlined,
                  onTap: () {},
                ),
                const PointyTotalLine(
                  label: 'الإجمالي',
                  value: '11.00',
                  isStrong: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
