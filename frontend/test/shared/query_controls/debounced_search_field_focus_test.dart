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
}
