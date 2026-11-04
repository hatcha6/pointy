import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/command_palette/command_palette.dart';

/// On an Arabic layout the K key types «ن», so a chord matched on the
/// logical key alone never fires for the shops this app is built for.
void main() {
  KeyDownEvent down(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) =>
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: Duration.zero,
      );

  testWidgets('Ctrl+K is the K key, whatever letter it types', (tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final arabicNoon = LogicalKeyboardKey(0x0646);

    expect(
      commandPaletteHotkey.accepts(down(PhysicalKeyboardKey.keyK, arabicNoon)),
      isTrue,
    );
    expect(
      commandPaletteHotkey.accepts(
        down(PhysicalKeyboardKey.keyK, LogicalKeyboardKey.keyK),
      ),
      isTrue,
    );
    expect(
      commandPaletteHotkey.accepts(
        down(PhysicalKeyboardKey.keyJ, LogicalKeyboardKey.keyJ),
      ),
      isFalse,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('a chord needs its modifiers, exactly', (tester) async {
    const hotkey = CommandHotkey(
      PhysicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyP,
      shift: true,
    );
    final p = down(PhysicalKeyboardKey.keyP, LogicalKeyboardKey.keyP);

    expect(hotkey.accepts(p), isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(hotkey.accepts(p), isFalse, reason: 'Shift is part of it');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(hotkey.accepts(p), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });
}
