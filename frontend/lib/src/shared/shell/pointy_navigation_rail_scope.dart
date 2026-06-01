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
    required super.child,
  }) : super(notifier: controller);

  final bool isActive;
  final PointyNavigationRailController controller;

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
        super.updateShouldNotify(oldWidget);
  }
}
