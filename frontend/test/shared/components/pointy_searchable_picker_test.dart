import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/components/pointy_searchable_picker.dart';

/// The picker replaced a wall of chips that listed every saved option at once.
/// What has to hold: the menu only opens on demand, it filters the way an
/// Arabic typist spells things, and a miss turns into "create what I typed"
/// rather than a dead end.
void main() {
  const entries = [
    PointyPickerEntry<int>(value: 1, label: 'أحمر', keywords: 'red'),
    PointyPickerEntry<int>(value: 2, label: 'أزرق', keywords: 'blue'),
    PointyPickerEntry<int>(value: 3, label: 'قُطن', keywords: 'cotton'),
  ];

  Future<void> pump(
    WidgetTester tester, {
    List<PointyPickerEntry<int>> options = entries,
    ValueChanged<int>? onSelected,
    ValueChanged<String>? onCreate,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Directionality(
            textDirection: TextDirection.rtl,
            child: PointySearchablePicker<int>(
              entries: options,
              onSelected: onSelected ?? (_) {},
              onCreate: onCreate,
              createLabel: (typed) => 'إنشاء «$typed»',
              hintText: 'ابحث',
              clearTooltip: 'مسح',
              noMatchText: 'لا يوجد مطابق',
              emptyText: 'اكتب اسمًا لإنشائه',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The field debounces, so a query needs a beat before the menu reflects it.
  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('the menu stays closed until the field is touched', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('أحمر'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.text('أحمر'), findsOneWidget);
    expect(find.text('أزرق'), findsOneWidget);
  });

  testWidgets('typing filters the menu', (tester) async {
    await pump(tester);
    await search(tester, 'أز');

    expect(find.text('أزرق'), findsOneWidget);
    expect(find.text('أحمر'), findsNothing);
  });

  testWidgets('search folds hamza and harakat the way people type them', (
    tester,
  ) async {
    await pump(tester);

    // "احمر" without the hamza still finds "أحمر".
    await search(tester, 'احمر');
    expect(find.text('أحمر'), findsOneWidget);

    // "قطن" without the damma still finds "قُطن".
    await search(tester, 'قطن');
    expect(find.text('قُطن'), findsOneWidget);
  });

  testWidgets('an entry can be found by its latin code', (tester) async {
    await pump(tester);
    await search(tester, 'blue');

    expect(find.text('أزرق'), findsOneWidget);
    expect(find.text('أحمر'), findsNothing);
  });

  testWidgets('picking a row reports it and clears the search', (tester) async {
    int? picked;
    await pump(tester, onSelected: (value) => picked = value);
    await search(tester, 'أز');
    await tester.tap(find.text('أزرق'));
    await tester.pumpAndSettle();

    expect(picked, 2);
    expect(find.text('أزرق'), findsNothing, reason: 'the menu closes');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('arrow keys move the highlight and Enter picks it', (
    tester,
  ) async {
    int? picked;
    await pump(tester, onSelected: (value) => picked = value);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    // Down from the first row lands on the second.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(picked, 2);
  });

  testWidgets('the highlight wraps around at the ends', (tester) async {
    int? picked;
    await pump(tester, onSelected: (value) => picked = value);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(picked, 3, reason: 'up from the first row lands on the last');
  });

  testWidgets('Escape dismisses the menu', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('أحمر'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('أحمر'), findsNothing);
  });

  testWidgets('a query with no match offers to create it', (tester) async {
    String? created;
    await pump(tester, onCreate: (typed) => created = typed);
    await search(tester, 'برتقالي');

    expect(find.text('لا يوجد مطابق'), findsNothing);
    await tester.tap(find.text('إنشاء «برتقالي»'));
    await tester.pumpAndSettle();

    expect(created, 'برتقالي');
  });

  testWidgets('creating is not offered for a name that already exists', (
    tester,
  ) async {
    await pump(tester, onCreate: (_) {});
    await search(tester, 'أحمر');

    // The query itself also renders inside the search field, so the row is
    // matched inside the menu list.
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('أحمر')),
      findsOneWidget,
    );
    expect(find.text('إنشاء «أحمر»'), findsNothing);
  });

  testWidgets('without a create callback a miss says so', (tester) async {
    await pump(tester);
    await search(tester, 'برتقالي');

    expect(find.text('لا يوجد مطابق'), findsOneWidget);
  });

  testWidgets('the menu lines up with the field it drops from', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final field = tester.getRect(find.byType(TextField));
    final menu = tester.getRect(
      find
          .ancestor(of: find.byType(ListView), matching: find.byType(Material))
          .first,
    );

    // Overlay children are laid out with tight constraints: without aligning
    // the menu back to its own size it silently spans the whole window.
    expect(menu.width, moreOrLessEquals(field.width, epsilon: 1));
    expect(menu.left, moreOrLessEquals(field.left, epsilon: 1));
    expect(menu.top, greaterThan(field.bottom));
  });

  testWidgets('a field near the bottom drops its menu upward', (tester) async {
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              PointySearchablePicker<int>(
                entries: entries,
                onSelected: (_) {},
                hintText: 'ابحث',
                clearTooltip: 'مسح',
                noMatchText: 'لا يوجد مطابق',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final field = tester.getRect(find.byType(TextField));
    final menu = tester.getRect(
      find
          .ancestor(of: find.byType(ListView), matching: find.byType(Material))
          .first,
    );

    expect(menu.bottom, lessThanOrEqualTo(field.top));
  });

  testWidgets('an empty list points at creating instead of showing nothing', (
    tester,
  ) async {
    await pump(tester, options: const [], onCreate: (_) {});
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.text('اكتب اسمًا لإنشائه'), findsOneWidget);
  });
}
