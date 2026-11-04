import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/pin_boxes.dart';

void main() {
  Future<List<double>> widths(WidgetTester tester, double room) async {
    final controller = TextEditingController(text: '12');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: room,
              child: PinBoxes(controller: controller),
            ),
          ),
        ),
      ),
    );
    return [
      for (final box in find.byType(AnimatedContainer).evaluate())
        tester.getSize(find.byWidget(box.widget)).width,
    ];
  }

  testWidgets('six full boxes where there is room', (tester) async {
    expect(await widths(tester, 340), everyElement(46));
  });

  testWidgets('all six still fit the narrowest phone, narrower', (
    tester,
  ) async {
    // 320 wide, less the sheet's margins. An overflow fails the test too.
    final boxes = await widths(tester, 272);
    expect(boxes, hasLength(6));
    expect(boxes, everyElement(lessThan(46)));
    expect(boxes, everyElement(greaterThan(32)));
  });
}
