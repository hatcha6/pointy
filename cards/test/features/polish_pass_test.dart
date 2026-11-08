import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/shell/cards_shell.dart';
import 'package:pointy_cards/src/shared/pill.dart';

/// The polishing pass of 2026-11-07: what a customer saw that read as unfinished.
void main() {
  Future<void> phone(WidgetTester tester, {double height = 844}) async {
    tester.view.physicalSize = Size(390, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('«كروتي» keeps its filter when the shell rebuilds', (
    tester,
  ) async {
    // The page was keyed afresh on every build of the shell: opening the
    // keyboard or turning the phone threw the filter (and the list) away.
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: const CardsShell(initialTab: 1),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('مستخدم'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-empty-used')), findsOneWidget);

    tester.view.physicalSize = const Size(390, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-empty-used')), findsOneWidget);
  });

  testWidgets('an empty filter says how a card gets there', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: const CardsShell(initialTab: 1),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('مستخدم'));
    await tester.pumpAndSettle();
    expect(find.text('لا كروت مستخدمة بعد'), findsOneWidget);
    expect(find.textContaining('«استخدمته»'), findsOneWidget);

    // A filter with cards in it shows them, not the note.
    await tester.tap(find.text('غير مستخدم'));
    await tester.pumpAndSettle();
    expect(find.text('لا كروت مستخدمة بعد'), findsNothing);
    expect(find.byKey(const ValueKey('filter-empty-unused')), findsNothing);
  });

  testWidgets('the shelf does not say the same thing twice', (tester) async {
    // Tall enough that every shelf is built.
    await phone(tester, height: 2400);
    await tester.pumpWidget(
      CardsApp(dependencies: fixtureDependencies(), home: const CardsShell()),
    );
    await tester.pumpAndSettle();

    // «الأكثر طلباً» is the carousel's title; its cards do not wear it too.
    // Libyana still does on the telecom shelf below.
    final mostWanted = find.descendant(
      of: find.byType(Pill),
      matching: find.text('الأكثر طلباً'),
    );
    expect(mostWanted, findsOneWidget);
  });
}
