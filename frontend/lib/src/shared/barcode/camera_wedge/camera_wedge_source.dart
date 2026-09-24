/// Where a camera wedge's scans come from.
///
/// Two very different machines sit behind this seam, and the difference is
/// which side of the FFI boundary the decoding happens on:
///
/// | backend | platforms | decodes | confirms |
/// |---|---|---|---|
/// | `mobile_scanner` | android, ios, macos, web | the OS (ML Kit, Vision) | Dart ([CameraWedgePolicy]) |
/// | native (`packages/pointy_camera_wedge`) | windows | zxing-cpp, in C++ | C++ (the same rule) |
///
/// The tills are Windows, and there the whole wedge — the camera's video
/// stream, zxing-cpp, the agreement between looks — runs on native threads;
/// Dart receives finished scans and nothing else, the way it receives
/// keystrokes from a hardware scanner. It replaced a Dart loop that took a
/// PHOTO about once a second through `camera_windows`, saved it as a JPEG and
/// decoded that, which is why reading a barcode used to take seconds.
///
/// Either way, a source hands over only scans it stands behind: the screen
/// on the other end treats them exactly as it treats the counter wedge. A
/// platform with no source reports [CameraWedgeBackend.none] and the feature
/// is offered nowhere, rather than throwing when someone taps it.
library;

import 'package:flutter/foundation.dart';

import 'camera_wedge_health.dart';
import 'camera_wedge_policy.dart';

/// A camera the wedge could run on. `id` is whatever the backend uses to
/// address it and is never shown; `label` is what the shop sees.
///
/// On Windows the id is `"<display name> <<symbolic link>>"`:
///
///     Integrated Webcam <\\?\usb#vid_1bcf&pid_2b94&mi_00#6&316f151d&0&0000#{e5323777-…}\global>
///
/// That is the shape `camera_windows` gave device names, and it is kept so a
/// camera a shop picked before the native wedge is still the camera picked
/// after it: the stored string matches the new one exactly, and the native
/// library reads the symbolic link back out of it. Only the display half is
/// ever shown — showing the whole string once put a Media Foundation symbolic
/// link in front of a cashier.
class CameraWedgeDevice {
  const CameraWedgeDevice({required this.id, required this.label});

  /// Split a platform device name into the part to keep and the part to show.
  ///
  /// The suffix is stripped by the rule `camera_windows` used to read it
  /// (last space, `<` after it, `>` at the end) — which the native library's
  /// `NormalizeDeviceId` mirrors. A name that does not match that shape is
  /// shown whole rather than guessed at: a half-cut label is worse than an
  /// honest one.
  factory CameraWedgeDevice.fromPlatformName(String name) =>
      CameraWedgeDevice(id: name, label: displayNameFrom(name));

  /// A native device, given the id shape described on the class.
  factory CameraWedgeDevice.native({
    required String label,
    required String nativeId,
  }) => CameraWedgeDevice(id: '$label <$nativeId>', label: label);

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
  /// ZXing on the web) decodes, and [CameraWedgePolicy] confirms in Dart.
  platformScanner,

  /// `packages/pointy_camera_wedge`: the camera stream, zxing-cpp and the
  /// confirmation policy all in native code. The desktop tills' path.
  native,

  /// Nothing available. The feature is hidden rather than broken.
  none,
}

/// A running camera, reporting scans it stands behind.
///
/// Confirmation (enough agreeing looks for the symbology, one read per item
/// left under the lens) is the source's job, not its caller's: on the native
/// backend it happens before anything reaches Dart at all.
abstract class CameraWedgeSource {
  /// Confirmed scans, in the order a till should act on them.
  Stream<CameraWedgeScan> get scans;

  /// What the camera is doing: starting, running, or why it is not.
  ValueListenable<CameraWedgeHealth> get health;

  /// The newest frame while [setPreviewEnabled] is on, for aiming the camera.
  /// Always null on a source that cannot provide one ([supportsPreview]).
  ValueListenable<CameraWedgePreviewFrame?> get preview;

  bool get supportsPreview;

  /// Cameras this backend can see. May be empty before [start] on platforms
  /// that only reveal device labels once permission is granted.
  Future<List<CameraWedgeDevice>> devices();

  /// Begin watching. Safe to call when already started.
  Future<void> start({String? deviceId});

  /// Stop watching and release the camera. Safe to call when not started.
  Future<void> stop();

  /// Ask for preview frames, or stop them. Off by default: frames are only
  /// copied out for Dart while somebody is looking at them.
  void setPreviewEnabled(bool enabled);

  Future<void> dispose();
}
