import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keyboard shortcuts that answer wherever focus sits on the current route.
///
/// Focus-tree [Shortcuts] only hear a key while focus is inside them, and
/// focus leaves easily: a text field's "done" action unfocuses it, and a
/// closed popup can hand focus to nothing at all. So these ride a
/// [HardwareKeyboard] handler instead — the reason the till's F-keys live on
/// `BarcodeScanListener` — and stay quiet whenever another route (a dialog, a
/// sheet, a picker) is on top of the one that declared them.
///
/// A binding returns whether it acted. One that did nothing lets the key go
/// on to whatever has focus.
class RouteKeyboardShortcuts extends StatefulWidget {
  const RouteKeyboardShortcuts({
    super.key,
    required this.bindings,
    required this.child,
    this.enabled = true,
  });

  /// Matched in order; the first activator that accepts the key decides it.
  final Map<ShortcutActivator, bool Function()> bindings;
  final Widget child;

  /// Off while the screen is busy (mid-save), so a key pressed then is not
  /// queued up as a second save.
  final bool enabled;

  @override
  State<RouteKeyboardShortcuts> createState() => _RouteKeyboardShortcutsState();
}

class _RouteKeyboardShortcutsState extends State<RouteKeyboardShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!widget.enabled || event is KeyUpEvent || !mounted) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    for (final MapEntry(key: activator, value: action)
        in widget.bindings.entries) {
      if (activator.accepts(event, HardwareKeyboard.instance)) {
        return action();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
