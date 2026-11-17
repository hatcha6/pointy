import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/pull_refresh.dart';

void main() {
  testWidgets('a refresh still running drops below the pinned header', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final done = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PullRefresh(
            onRefresh: () => done.future,
            scroll: scroll,
            pinnedAt: 160,
            pinnedExtent: 144,
            child: ListView.builder(
              controller: scroll,
              itemExtent: 80,
              itemCount: 40,
              itemBuilder: (context, index) => Text('$index'),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final spinner = find.byType(RefreshProgressIndicator);
    final atTop = tester.getTopLeft(spinner).dy;
    expect(atTop, lessThan(144));

    scroll.jumpTo(600);
    await tester.pump();
    // Clear of the header, by a gap.
    expect(tester.getTopLeft(spinner).dy, greaterThan(144 + 8));

    scroll.jumpTo(0);
    await tester.pump();
    expect(tester.getTopLeft(spinner).dy, atTop);

    done.complete();
    await tester.pumpAndSettle();
  });
}
