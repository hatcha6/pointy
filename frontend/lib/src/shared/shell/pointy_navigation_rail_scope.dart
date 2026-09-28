import 'package:flutter/widgets.dart';

import '../responsive/app_breakpoints.dart';
import 'pointy_navigation_scroll_store.dart';

class PointyNavigationRailController extends ChangeNotifier {
  /// Leave [isExpanded] null to let the window decide until the operator
  /// toggles the rail (see [isExpandedFor]); pass it to pin a starting state.
  PointyNavigationRailController({bool? isExpanded}) : _isExpanded = isExpanded;

  /// Narrowest window the rail opens extended in: whatever the 240px of labels
  /// leave must still be desktop-wide. A 1024×768 till therefore opens with
  /// the rail folded to its icons — extended, it left the till's catalog one
  /// product card across.
  static const double autoExpandMinWidth = AppBreakpoints.desktopMin + 240;

  /// The operator's own choice; null until they make one.
  bool? _isExpanded;

  /// Whether the rail is extended in a window [width] wide: the operator's
  /// choice once they have made one — it holds for the rest of the session —
  /// and otherwise only where the window has room for the labels.
  bool isExpandedFor(double width) {
    return _isExpanded ?? width >= autoExpandMinWidth;
  }

  void setExpanded(bool value) {
    if (_isExpanded == value) {
      return;
    }
    _isExpanded = value;
    notifyListeners();
  }
}

class PointyNavigationRailScope
    extends InheritedNotifier<PointyNavigationRailController> {
  const PointyNavigationRailScope({
    super.key,
    required this.isActive,
    required this.controller,
    this.isExpanded = true,
    this.navigationScrollStore,
    required super.child,
  }) : super(notifier: controller);

  final bool isActive;
  final PointyNavigationRailController controller;

  /// Whether the rail under this scope is drawn extended, as the scaffold that
  /// draws it resolved it for the window. Only a scaffold's own scope is ever
  /// read for it; the app shell's, above every screen, keeps the default.
  final bool isExpanded;

  /// App-lifetime home for the drawer/rail list scroll offsets. Screens
  /// replace each other as routes, and the routes left underneath stay alive
  /// with a scroll position each, so the offset has to live above all of them
  /// or the navigation snaps back to an older place every time one is
  /// revealed. Null when no app shell provides one (tests, previews) — the
  /// surfaces then keep their own offset, as any list does.
  final PointyNavigationScrollStore? navigationScrollStore;

  static PointyNavigationRailScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PointyNavigationRailScope>();
  }

  /// Flips the rail from what is on screen — which, before the operator has
  /// chosen, is the window's default rather than any stored value.
  void toggleExpanded() {
    controller.setExpanded(!isExpanded);
  }

  @override
  bool updateShouldNotify(PointyNavigationRailScope oldWidget) {
    return isActive != oldWidget.isActive ||
        controller != oldWidget.controller ||
        isExpanded != oldWidget.isExpanded ||
        navigationScrollStore != oldWidget.navigationScrollStore ||
        super.updateShouldNotify(oldWidget);
  }
}
