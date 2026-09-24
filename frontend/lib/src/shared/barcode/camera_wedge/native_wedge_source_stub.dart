import 'camera_wedge_source.dart';

/// No FFI on this platform, so no native wedge.
bool get nativeCameraWedgeAvailable => false;

/// Why not, for logs.
String? get nativeCameraWedgeUnavailableReason =>
    'no native code on this platform';

CameraWedgeSource? createNativeWedgeSource() => null;
