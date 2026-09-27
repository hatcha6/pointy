import 'package:flutter/widgets.dart';

import 'camera_wedge_controller.dart';

/// Makes the counter camera reachable from any screen without threading it
/// through constructors.
///
/// Not for scanning: the camera's scans reach screens as keystrokes
/// (`ScanKeyboard`), so no screen looks the camera up to hear it. The
/// scope is for the few that talk ABOUT the camera — device settings, and the
/// shortcut sheet that mentions F8 only on a till that has one. Screens and
/// tests that do not want it get `null` and behave exactly as before.
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
