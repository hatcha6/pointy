import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/query_controls/debounced_search_field.dart';

/// Every screen feeds the field's (trimmed) report back into it as `value`,
/// the way the till's view model does. Field data (Sep 2026): writing that
/// echo into the field ate the space a cashier had just typed, so the next
/// word glued on — «هريسةمنز» was 11% of a grocery till's empty searches.
void main() {
  Future<_EchoingParentState> pumpEchoingParent(WidgetTester tester) async {
    final key = GlobalKey<_EchoingParentState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: PointyTheme.light(),
        home: Scaffold(body: _EchoingParent(key: key)),
      ),
    );
    return key.currentState!;
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  testWidgets('the echo of a report keeps the space the cashier typed', (
    tester,
  ) async {
    final parent = await pumpEchoingParent(tester);

    await tester.enterText(find.byType(EditableText), 'هريسة ');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(parent.reports, ['هريسة']);
    expect(fieldText(tester), 'هريسة ');
  });

  testWidgets('a late echo does not land on what was typed after it', (
    tester,
  ) async {
    final parent = await pumpEchoingParent(tester);

    await tester.enterText(find.byType(EditableText), 'هريسة');
    await tester.pump(const Duration(milliseconds: 400));
    // Typed on before the echo's rebuild ran.
    await tester.enterText(find.byType(EditableText), 'هريسة من');
    await tester.pump();

    expect(fieldText(tester), 'هريسة من');
    await tester.pump(const Duration(milliseconds: 400));
    expect(parent.reports, ['هريسة', 'هريسة من']);
  });

  testWidgets('a value from outside still replaces the text', (tester) async {
    final parent = await pumpEchoingParent(tester);

    await tester.enterText(find.byType(EditableText), 'حليب');
    await tester.pump(const Duration(milliseconds: 400));
    parent.setValueFromOutside('');
    await tester.pump();

    expect(fieldText(tester), '');
  });
}

class _EchoingParent extends StatefulWidget {
  const _EchoingParent({super.key});

  @override
  State<_EchoingParent> createState() => _EchoingParentState();
}

class _EchoingParentState extends State<_EchoingParent> {
  String value = '';
  final List<String> reports = [];

  void setValueFromOutside(String next) => setState(() => value = next);

  @override
  Widget build(BuildContext context) {
    return DebouncedSearchField(
      value: value,
      hintText: 'search',
      clearTooltip: 'clear',
      onChanged: (reported) {
        reports.add(reported);
        setState(() => value = reported);
      },
    );
  }
}
