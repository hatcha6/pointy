// Dev-only, safe to delete, never imported by lib/main.dart.
//
// Puts a real screen into a state it only reaches through input — a picked
// dropdown value, a typed price, a chosen tab — by acting on the live widget
// tree the way a tap would, so the marketing preview can be screenshotted
// without a click script. Everything goes through the widgets' own callbacks;
// nothing reaches into private state.
import 'package:flutter/material.dart';

/// The first element below the root whose widget satisfies [test].
Element? findElement(bool Function(Widget widget) test) {
  Element? found;
  void visit(Element element) {
    if (found != null) {
      return;
    }
    if (test(element.widget)) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

/// Polls each frame-ish until [find] answers, for up to [timeout].
Future<Element?> waitForElement(
  bool Function(Widget widget) test, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final element = findElement(test);
    if (element != null) {
      return element;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return null;
}

/// Types [text] into the text field labelled [label], as a person would.
Future<bool> typeInto(String label, String text) async {
  final element = await waitForElement(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );
  final controller = (element?.widget as TextField?)?.controller;
  if (controller == null) {
    return false;
  }
  controller.text = text;
  return true;
}

/// Picks [value] in the dropdown form field keyed [key], firing its onChanged.
Future<bool> pickDropdown<T>(Key key, T value) async {
  final element = await waitForElement((widget) => widget.key == key);
  if (element is! StatefulElement) {
    return false;
  }
  final state = element.state;
  if (state is! FormFieldState<T>) {
    return false;
  }
  state.didChange(value);
  return true;
}

/// Picks [value] in the first `DropdownButtonFormField<T>` on screen.
Future<bool> pickFirstDropdown<T>(T value) async {
  final element = await waitForElement(
    (widget) => widget is DropdownButtonFormField<T>,
  );
  if (element is! StatefulElement) {
    return false;
  }
  final state = element.state;
  if (state is! FormFieldState<T>) {
    return false;
  }
  state.didChange(value);
  return true;
}

/// Switches the [TabBar]'s controller to [index].
Future<bool> selectTab(int index) async {
  final element = await waitForElement((widget) => widget is TabBar);
  if (element == null) {
    return false;
  }
  final controller =
      (element.widget as TabBar).controller ??
      DefaultTabController.maybeOf(element);
  if (controller == null) {
    return false;
  }
  controller.index = index;
  return true;
}

/// Presses the first [IconButton] showing [icon] — e.g. a month arrow.
Future<bool> pressIconButton(IconData icon) async {
  final element = await waitForElement(
    (widget) =>
        widget is IconButton &&
        widget.icon is Icon &&
        (widget.icon as Icon).icon == icon &&
        widget.onPressed != null,
  );
  final button = element?.widget as IconButton?;
  if (button == null) {
    return false;
  }
  button.onPressed!();
  return true;
}

/// Presses the first enabled [FilledButton] (or `.icon` variant) on screen.
Future<bool> pressFilledButton() async {
  final element = await waitForElement(
    (widget) => widget is FilledButton && widget.onPressed != null,
  );
  final button = element?.widget as FilledButton?;
  if (button == null) {
    return false;
  }
  button.onPressed!();
  return true;
}
