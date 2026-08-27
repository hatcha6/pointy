import 'package:flutter/foundation.dart';

/// Whether `mobile_scanner` has a real implementation on this platform.
///
/// It has none on Windows or Linux, and asking anyway does not fail quietly:
/// the plugin binds an EventChannel, the channel answers `notImplemented`, and
/// the stream error arrives with no handler as an unhandled
/// `MissingPluginException`. A Windows till opening the barcode sheet reported
/// one every time.
///
/// Those tills scan with a wedge (a keyboard, as far as the app is concerned),
/// so nothing is lost by not offering the camera.
bool get cameraScanningSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;
