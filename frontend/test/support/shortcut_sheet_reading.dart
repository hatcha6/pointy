import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/components/pointy_shortcuts_sheet.dart';

/// What a shortcuts cheat sheet draws beside [description], read left to right
/// as it is on screen, joiners included: `['Ctrl', '+', 'Enter']`.
List<String> shortcutKeysBeside(WidgetTester tester, String description) {
  final row = find
      .ancestor(of: find.text(description), matching: find.byType(Row))
      .first;
  final labels = find.descendant(
    of: find.descendant(of: row, matching: find.byType(PointyKeyCombo)),
    matching: find.byType(Text),
  );
  final drawn = [
    for (final label in labels.evaluate())
      (
        left: (label.renderObject! as RenderBox).localToGlobal(Offset.zero).dx,
        text: (label.widget as Text).data!,
      ),
  ]..sort((a, b) => a.left.compareTo(b.left));
  return [for (final label in drawn) label.text];
}
