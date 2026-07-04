import 'package:flutter/widgets.dart';

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
    this.navigationBucket,
    required super.child,
  }) : super(notifier: controller);

  final bool isActive;
  final PointyNavigationRailController controller;

  /// App-lifetime storage for the drawer/rail list scroll offsets. Screens
  /// replace each other as routes (each route gets its own PageStorage), so
  /// without this app-level bucket the navigation list snaps back to the top
  /// on every page change. Null when no app shell provides one (tests,
  /// previews) — the surfaces then simply don't persist scroll.
  final PageStorageBucket? navigationBucket;

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
        navigationBucket != oldWidget.navigationBucket ||
        super.updateShouldNotify(oldWidget);
  }
}
