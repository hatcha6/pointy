import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/grouped.dart';

void main() {
  testWidgets('a label too long for its segment stays on one line', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: SegmentedPill<int>(
                segments: const [
                  (0, 'الكل'),
                  (1, 'غير مستخدمة وطويلة جداً'),
                  (2, 'مستخدم'),
                  (3, 'لم تكتمل'),
                ],
                selected: 0,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final long = find.text('غير مستخدمة وطويلة جداً');
    expect(tester.widget<Text>(long).maxLines, 1);
    // Scaled to its segment, a quarter of the pill, with nothing cut off.
    // Measured on screen: the scale is a transform, not the text's own size.
    final shown = tester.getBottomRight(long) - tester.getTopLeft(long);
    expect(shown.dx.abs(), lessThanOrEqualTo(280 / 4));
    expect(shown.dy.abs(), lessThanOrEqualTo(40));
  });
}
