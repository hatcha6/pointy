import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/grouped.dart';

void main() {
  testWidgets('a long grouped list builds only the rows on screen', (
    tester,
  ) async {
    final built = <int>{};
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: scroll,
            slivers: [
              GroupedSliver(
                itemCount: 300,
                itemBuilder: (context, index) {
                  built.add(index);
                  return SizedBox(height: 60, child: Text('row $index'));
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(built, isNotEmpty);
    expect(built.length, lessThan(30));
    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 299'), findsNothing);

    // A lazy list's end is an estimate that settles as rows are built.
    for (var i = 0; i < 6; i++) {
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
    }
    expect(find.text('row 299'), findsOneWidget);
  });

  testWidgets('an empty grouped list takes no room', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [GroupedSliver(itemCount: 0, itemBuilder: (_, _) => null)],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
