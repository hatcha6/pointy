import 'package:flutter/widgets.dart';

import 'pointy_navigation_scroll_store.dart';

class PointyNavigationRailController extends ChangeNotifier {
  PointyNavigationRailController({bool isExpanded = true})
    : _isExpanded = isExpanded;

  bool _isExpanded;

  bool get isExpanded => _isExpanded;

  void toggleExpanded() {
    setExpanded(!_isExpanded);
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
    this.navigationScrollStore,
    required super.child,
  }) : super(notifier: controller);

  final bool isActive;
  final PointyNavigationRailController controller;

  /// App-lifetime home for the drawer/rail list scroll offsets. Screens
  /// replace each other as routes, and the routes left underneath stay alive
  /// with a scroll position each, so the offset has to live above all of them
  /// or the navigation snaps back to an older place every time one is
  /// revealed. Null when no app shell provides one (tests, previews) — the
  /// surfaces then keep their own offset, as any list does.
  final PointyNavigationScrollStore? navigationScrollStore;

  bool get isExpanded => controller.isExpanded;

  static PointyNavigationRailScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PointyNavigationRailScope>();
  }

  void toggleExpanded() {
    controller.toggleExpanded();
  }

  @override
  bool updateShouldNotify(PointyNavigationRailScope oldWidget) {
    return isActive != oldWidget.isActive ||
        controller != oldWidget.controller ||
        navigationScrollStore != oldWidget.navigationScrollStore ||
        super.updateShouldNotify(oldWidget);
  }
}
