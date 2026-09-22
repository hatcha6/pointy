/// Where a camera wedge's readings come from.
///
/// The seam exists because **no single Flutter camera API spans the platforms
/// Pointy ships on**, and the one that is missing is the one that matters. Read
/// out of the packages rather than recalled:
///
/// | package | platforms |
/// |---|---|
/// | `mobile_scanner` (used here) | android, ios, macos, web |
/// | `camera` | android, ios, web |
/// | `camera_windows` | windows — but `startImageStream` throws `UnimplementedError` |
/// | `flutter_webrtc` | everything, but `captureFrame()` round-trips a PNG through disk |
///
/// The tills are Windows. So the *policy* — how many agreeing looks a
/// symbology needs, how long to hold off a re-read — is platform-agnostic pure
/// Dart in [CameraWedgePolicy], and only the plumbing behind this interface
/// differs. A platform with no source reports [CameraWedgeBackend.none] and the
/// feature is offered nowhere, rather than throwing when someone taps it (the
/// `MissingPluginException` every Windows till used to log when the old camera
/// sheet was opened — see `camera_scanning_support.dart`).
library;

import 'camera_wedge_policy.dart';

/// A camera the wedge could run on. `id` is whatever the backend uses to
/// address it and is never shown; `label` is what the shop sees.
///
/// Those two are NOT the same string on Windows, and treating them as one is
/// what put a MediaFoundation symbolic link in front of a cashier:
///
///     Integrated Webcam <\\?\usb#vid_1bcf&pid_2b94&mi_00#6&316f151d&0&0000#{e5323777-…}\global>
///
/// `camera_windows` builds that string itself — `display_name + " <" +
/// device_id + ">"` in `CaptureDeviceInfo::GetUniqueDeviceName` — and parses
/// the whole thing back apart when it is asked to open the camera. So the id
/// has to be kept intact, and only the display half may be shown.
class CameraWedgeDevice {
  const CameraWedgeDevice({required this.id, required this.label});

  /// Split a platform device name into the part to keep and the part to show.
  ///
  /// The suffix is stripped by the same rule `camera_windows` uses to read it
  /// (`CaptureDeviceInfo::ParseDeviceInfoFromCameraName`: last space, `<`
  /// after it, `>` at the end). A name that does not match that shape is
  /// shown whole rather than guessed at — every other platform's names are
  /// already human, and a half-cut label is worse than an honest one.
  factory CameraWedgeDevice.fromPlatformName(String name) =>
      CameraWedgeDevice(id: name, label: displayNameFrom(name));

  final String id;
  final String label;

  /// The shop-facing half of a platform device name. Exposed for tests; the
  /// rest of the app goes through [CameraWedgeDevice.fromPlatformName].
  static String displayNameFrom(String name) {
    if (!name.endsWith('>')) return name;
    final space = name.lastIndexOf(' ');
    if (space <= 0 || space + 1 >= name.length) return name;
    if (name[space + 1] != '<') return name;
    final display = name.substring(0, space).trim();
    // A device that reports nothing but an id still needs a row to pick.
    return display.isEmpty ? name : display;
  }

  /// Make every label in [devices] distinct.
  ///
  /// A till with two identical webcams — the common case for the one facing
  /// the cashier and the one on the stand — would otherwise show the same
  /// name twice with no way to tell which is which, and picking the counter
  /// camera would be a coin flip. Numbering them is not informative, but it
  /// is honest about there being two, and the pick is remembered.
  static List<CameraWedgeDevice> disambiguated(
    List<CameraWedgeDevice> devices,
  ) {
    final counts = <String, int>{};
    for (final device in devices) {
      counts[device.label] = (counts[device.label] ?? 0) + 1;
    }
    final seen = <String, int>{};
    return [
      for (final device in devices)
        if ((counts[device.label] ?? 0) < 2)
          device
        else
          CameraWedgeDevice(
            id: device.id,
            label:
                '${device.label} '
                '(${seen[device.label] = (seen[device.label] ?? 0) + 1})',
          ),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is CameraWedgeDevice && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'CameraWedgeDevice($label)';
}

/// Which implementation this platform would use, if any.
enum CameraWedgeBackend {
  /// `mobile_scanner`: the platform's own detector (ML Kit, Apple Vision,
  /// ZXing on the web). It decodes in native code and hands over values, so
  /// the wedge never sees pixels here. 1-D and 2-D.
  platformScanner,

  /// Stills through `camera_windows`/`camera_linux`, decoded by zxing-cpp
  /// through `flutter_zxing`. The desktop till's path, because there is no
  /// image stream there. 1-D and 2-D, and the same engine the backend and the
  /// measurement lab use — so it is slower than a live stream, not narrower.
  snapshot,

  /// Nothing available. The feature is hidden rather than broken.
  none,
}

/// A running camera, reporting what it thinks it sees.
///
/// Implementations report EVERY decode, including repeats — the policy needs
/// them to reach agreement, and a source that de-duplicates internally would
/// silently make every 1-D scan impossible. That is a real trap: it is the
/// default in `mobile_scanner` (`DetectionSpeed.noDuplicates`).
abstract class CameraWedgeSource {
  /// Every decode, unfiltered and un-deduplicated.
  Stream<CameraWedgeReading> get readings;

  /// Cameras this backend can see. May be empty before [start] on platforms
  /// that only reveal device labels once permission is granted.
  Future<List<CameraWedgeDevice>> devices();

  /// Begin watching. Safe to call when already started.
  Future<void> start({String? deviceId});

  /// Stop watching and release the camera. Safe to call when not started.
  Future<void> stop();

  Future<void> dispose();
}
