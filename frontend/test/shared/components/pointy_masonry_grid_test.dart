import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('packs each card into the shortest column with no dead space', (
    tester,
  ) async {
    await _pumpGrid(
      tester,
      width: 640,
      children: const [
        SizedBox(key: Key('a'), height: 200),
        SizedBox(key: Key('b'), height: 100),
        SizedBox(key: Key('c'), height: 80),
      ],
    );

    final a = tester.getTopLeft(find.byKey(const Key('a')));
    final b = tester.getTopLeft(find.byKey(const Key('b')));
    final c = tester.getTopLeft(find.byKey(const Key('c')));

    // Two columns at 640 px: the first two cards top out each column together.
    expect(b.dy, a.dy);
    // The third card flows up under the shorter column instead of waiting for
    // the tall card to finish — this is the band the old Wrap layout wasted.
    expect(c.dy, greaterThan(b.dy));
    expect(c.dy, lessThan(a.dy + 200));
    expect(c.dx, b.dx);
    // RTL: column 0 (a) is laid out to the right of column 1 (b).
    expect(a.dx, greaterThan(b.dx));

    expect(tester.takeException(), isNull);
  });

  testWidgets('collapses to a single stacked column when narrow', (
    tester,
  ) async {
    await _pumpGrid(
      tester,
      width: 320,
      children: const [
        SizedBox(key: Key('a'), height: 150),
        SizedBox(key: Key('b'), height: 90),
      ],
    );

    final a = tester.getTopLeft(find.byKey(const Key('a')));
    final b = tester.getTopLeft(find.byKey(const Key('b')));

    expect(a.dx, b.dx);
    expect(b.dy - a.dy, greaterThanOrEqualTo(150));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpGrid(
  WidgetTester tester, {
  required double width,
  required List<Widget> children,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: PointyMasonryGrid(
                  minTileWidth: 300,
                  maxColumns: 4,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
