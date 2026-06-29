import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Registers/unregisters the Windows client to launch automatically at user
/// login, via the native `pointy/autostart` channel (a `HKCU\…\Run` value).
///
/// A no-op everywhere else: the channel is only registered in the Windows
/// runner, so other platforms hit [MissingPluginException] and report
/// "unsupported" / `false` rather than throwing. Uses [defaultTargetPlatform]
/// (not `dart:io`) so the file stays safe to compile for web.
class AutoStartService {
  const AutoStartService();

  static const _channel = MethodChannel('pointy/autostart');

  /// Whether launch-on-startup can be controlled on this platform (Windows).
  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Whether the app is currently registered to start at login.
  Future<bool> isEnabled() async {
    if (!isSupportedPlatform) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Registers (or clears) the startup entry. Returns the resulting state, or
  /// `false` when unsupported / on failure.
  Future<bool> setEnabled(bool enabled) async {
    if (!isSupportedPlatform) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'setEnabled',
            {'enabled': enabled},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
