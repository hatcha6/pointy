import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/query_controls/debounced_search_field.dart';

/// The till's top-up box puts a search button after the text. A tap has to
/// act on what is in the box NOW — a cashier who types a card number and taps
/// at once is inside the debounce window, and acting on the last reported
/// text would search for a number they have already typed past.
void main() {
  testWidgets('a trailing action submits what is typed, debounce or not', (
    tester,
  ) async {
    final submitted = <String>[];
    final changes = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Scaffold(
          body: DebouncedSearchField(
            value: '',
            hintText: 'search',
            clearTooltip: 'clear',
            onChanged: changes.add,
            onSubmitted: (value) {
              submitted.add(value);
              return false;
            },
            trailingBuilder: (context, submit) => IconButton(
              key: const ValueKey('go'),
              onPressed: submit,
              icon: const Icon(Icons.search),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(EditableText), '210906803499');
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pump();
    expect(submitted, ['210906803499']);

    await tester.pump(const Duration(milliseconds: 400));
    expect(
      changes,
      ['210906803499'],
      reason: 'reported once, by the submit — the debounce it overtook is off',
    );
  });

  testWidgets('without one, the field keeps its single clear button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Scaffold(
          body: DebouncedSearchField(
            value: 'abc',
            hintText: 'search',
            clearTooltip: 'clear',
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget, reason: 'the prefix');
    expect(find.byType(IconButton), findsOneWidget);
  });
}
