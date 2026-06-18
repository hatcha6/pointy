import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import '../../data/services/device_settings_storage_service.dart';

/// Holds the active [ThemeMode] and persists changes to the device.
///
/// Theme is a per-device preference rather than an account one: a dim shop
/// floor can run dark while the back office runs light. It is loaded from
/// [DeviceSettingsStorageService] on startup and written back on every change.
class ThemeController extends ChangeNotifier {
  ThemeController({
    DeviceSettingsStorageService storage = const DeviceSettingsStorageService(),
    ThemeMode initialMode = ThemeMode.system,
  }) : _storage = storage,
       _mode = initialMode;

  final DeviceSettingsStorageService _storage;

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Loads the persisted preference, if any. Safe to call once at startup.
  Future<void> load() async {
    final stored = await _storage.loadThemeMode();
    if (stored != null && stored != _mode) {
      _mode = stored;
      notifyListeners();
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
    await _storage.saveThemeMode(mode);
  }

  /// One-tap toggle for the app-bar control: flips between light and dark based
  /// on what is *currently showing*. (System mode stays reachable from the
  /// appearance settings.)
  Future<void> toggleLightDark() {
    return setMode(resolvedIsDark ? ThemeMode.light : ThemeMode.dark);
  }

  /// Whether the app is rendering dark right now, resolving [ThemeMode.system]
  /// against the platform brightness.
  bool get resolvedIsDark {
    if (_mode == ThemeMode.system) {
      return PlatformDispatcher.instance.platformBrightness == Brightness.dark;
    }
    return _mode == ThemeMode.dark;
  }
}

/// Makes the [ThemeController] available to any descendant (drawer, settings,
/// app-bar toggle) and rebuilds them when the mode changes.
class ThemeControllerScope extends InheritedNotifier<ThemeController> {
  const ThemeControllerScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ThemeControllerScope>();
    assert(scope?.notifier != null, 'No ThemeControllerScope in the tree');
    return scope!.notifier!;
  }

  static ThemeController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ThemeControllerScope>()
        ?.notifier;
  }
}
