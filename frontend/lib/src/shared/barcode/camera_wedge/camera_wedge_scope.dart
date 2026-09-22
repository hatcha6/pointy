import 'package:flutter/widgets.dart';

import 'camera_wedge_controller.dart';

/// Makes the counter camera reachable from any screen without threading it
/// through constructors.
///
/// Exactly the shape `CompanionScope` uses, for exactly the same reason:
/// scanning is ambient — it belongs to every scanning surface at once — so
/// passing a controller down through POS, purchasing, stock count and half a
/// dozen dialogs would mean editing each of them, and every preview harness
/// and widget test that builds one, to add a parameter they only forward. A
/// scope keeps the feature additive: screens that want it look it up, screens
/// and tests that do not get `null` and behave exactly as before.
class CameraWedgeScope extends InheritedWidget {
  const CameraWedgeScope({
    super.key,
    required this.controller,
    required super.child,
  });

  /// Null before sign-in, where the platform has no camera source, where the
  /// shop has not switched it on, and in previews and tests.
  final CameraWedgeController? controller;

  static CameraWedgeScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<CameraWedgeScope>();
  }

  static CameraWedgeController? controllerOf(BuildContext context) {
    return maybeOf(context)?.controller;
  }

  @override
  bool updateShouldNotify(CameraWedgeScope oldWidget) {
    return controller != oldWidget.controller;
  }
}
