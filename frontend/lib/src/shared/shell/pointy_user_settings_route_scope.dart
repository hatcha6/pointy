import 'package:flutter/widgets.dart';

typedef PointyUserSettingsRouteLauncher = void Function(BuildContext context);

class PointyUserSettingsRouteScope extends InheritedWidget {
  const PointyUserSettingsRouteScope({
    super.key,
    required super.child,
    required this.onOpenUserSettings,
  });

  final PointyUserSettingsRouteLauncher onOpenUserSettings;

  static PointyUserSettingsRouteScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PointyUserSettingsRouteScope>();
  }

  @override
  bool updateShouldNotify(PointyUserSettingsRouteScope oldWidget) {
    return onOpenUserSettings != oldWidget.onOpenUserSettings;
  }
}
