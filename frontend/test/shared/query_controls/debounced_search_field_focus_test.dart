import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/query_controls/debounced_search_field.dart';

/// The POS returns keyboard focus to the catalog search between the cashier's
/// actions by owning the field's focus node and calling requestFocus on it.
/// This proves an externally-owned focus node is genuinely wired to the field,
/// so that mechanism works.
void main() {
  testWidgets('an external focus node drives the search field focus', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Scaffold(
          body: DebouncedSearchField(
            value: '',
            hintText: 'search',
            clearTooltip: 'clear',
            onChanged: (_) {},
            focusNode: focusNode,
          ),
        ),
      ),
    );

    expect(focusNode.hasFocus, isFalse);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isFalse);

    // Pulling focus via the caller-owned node focuses the field itself.
    focusNode.requestFocus();
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
  });

  // The POS fires a reset signal after a hardware scan so the scanner's key
  // burst (which briefly types into the focused search field and queues a
  // debounced search) can't push the barcode back into the field.
  testWidgets('a reset signal clears the field and cancels its debounce', (
    tester,
  ) async {
    final reset = ValueNotifier<int>(0);
    addTearDown(reset.dispose);
    final changes = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Scaffold(
          body: DebouncedSearchField(
            value: '',
            hintText: 'search',
            clearTooltip: 'clear',
            debounceDuration: const Duration(milliseconds: 300),
            onChanged: changes.add,
            resetSignal: reset,
          ),
        ),
      ),
    );

    // Type a "barcode" — its search is debounced, not yet delivered.
    await tester.enterText(find.byType(TextField), '12345');
    expect(find.text('12345'), findsOneWidget);
    expect(changes, isEmpty);

    // Fire the reset before the debounce elapses.
    reset.value++;
    await tester.pump();

    // The field is cleared right away and the query is reset to empty.
    expect(find.text('12345'), findsNothing);
    expect(changes, ['']);

    // The queued debounce is dead — it never delivers the typed barcode.
    await tester.pump(const Duration(milliseconds: 400));
    expect(changes, ['']);
  });
}
