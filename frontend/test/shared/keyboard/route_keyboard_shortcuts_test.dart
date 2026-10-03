import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/keyboard/route_keyboard_shortcuts.dart';

/// Shortcuts that must answer wherever focus sits — including nowhere, which
/// is where a text field's "done" leaves it — and fall silent under a dialog.
void main() {
  late int saves;
  late bool handles;

  Future<GlobalKey<NavigatorState>> pumpScreen(WidgetTester tester) async {
    saves = 0;
    handles = true;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: RouteKeyboardShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
              ): () {
                saves += 1;
                return handles;
              },
            },
            child: const TextField(),
          ),
        ),
      ),
    );
    return navigatorKey;
  }

  Future<void> pressCtrlEnter(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('answers with nothing focused', (tester) async {
    await pumpScreen(tester);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );

    await pressCtrlEnter(tester);

    expect(saves, 1);
  });

  testWidgets('answers from inside a text field', (tester) async {
    await pumpScreen(tester);
    await tester.showKeyboard(find.byType(TextField));

    await pressCtrlEnter(tester);

    expect(saves, 1);
  });

  testWidgets('a plain Enter is not the shortcut', (tester) async {
    await pumpScreen(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(saves, 0);
  });

  testWidgets('falls silent while a dialog is on top', (tester) async {
    final navigator = await pumpScreen(tester);
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();

    await pressCtrlEnter(tester);

    expect(saves, 0);
  });

  testWidgets('a binding that did nothing leaves the key unhandled', (
    tester,
  ) async {
    await pumpScreen(tester);

    Future<bool> ctrlEnter() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final handled = await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      return handled;
    }

    expect(await ctrlEnter(), isTrue);
    handles = false;
    expect(await ctrlEnter(), isFalse);
    expect(saves, 2);
  });
}
