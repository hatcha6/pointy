import 'package:flutter/foundation.dart';

import 'camera_wedge_policy.dart';

/// Where the counter camera is in its life.
enum CameraWedgeState { stopped, starting, running, recovering }

/// Why the counter camera is not reading, in terms a shop can act on.
///
/// Kept apart on purpose: "the camera is in use by another program" and
/// "Windows is blocking camera access" have different fixes, and the first
/// field report of this feature was a camera failing for a whole shift under a
/// single "the camera is working" message.
enum CameraWedgeFault {
  none,
  noCamera,
  deviceNotFound,
  accessDenied,
  inUse,
  deviceLost,
  noUsableFormat,
  stalled,
  platform,
  unsupported,
}

/// Counters from a running camera, about once a second.
@immutable
class CameraWedgeStats {
  const CameraWedgeStats({
    this.captureFps = 0,
    this.framesCaptured = 0,
    this.framesDecoded = 0,
    this.decodeMilliseconds = 0,
    this.scans = 0,
    this.rejectedDisagreements = 0,
    this.suppressedRereads = 0,
    this.active = false,
  });

  final double captureFps;
  final int framesCaptured;
  final int framesDecoded;

  /// How long one decode pass takes on this machine.
  final double decodeMilliseconds;
  final int scans;

  /// Reads thrown away because a second look disagreed: each one a wrong
  /// product that did not reach a cart.
  final int rejectedDisagreements;
  final int suppressedRereads;

  /// Decoding every frame because something moved or was read, rather than
  /// idling at a few frames a second.
  final bool active;
}

/// Everything the settings page and the preview panel say about the camera.
@immutable
class CameraWedgeHealth {
  const CameraWedgeHealth({
    required this.state,
    this.fault = CameraWedgeFault.none,
    this.detail = '',
    this.deviceLabel = '',
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.pixelFormat = '',
    this.substitutedDevice = false,
    this.retryIn = Duration.zero,
    this.stats,
    this.lastScan,
    this.lastScanAt,
  });

  static const stopped = CameraWedgeHealth(state: CameraWedgeState.stopped);

  final CameraWedgeState state;
  final CameraWedgeFault fault;

  /// Raw detail (an HRESULT, the step that failed): for support, never shown
  /// to a cashier on its own.
  final String detail;
  final String deviceLabel;
  final int width;
  final int height;
  final double fps;

  /// What the camera sends and what it is turned into, e.g. "MJPG>NV12".
  final String pixelFormat;

  /// The picked camera is absent and the only other one is reading instead.
  final bool substitutedDevice;

  /// When recovering: how long until it tries again, by itself.
  final Duration retryIn;
  final CameraWedgeStats? stats;
  final CameraWedgeScan? lastScan;
  final DateTime? lastScanAt;

  bool get isRunning => state == CameraWedgeState.running;

  /// Whether a picture is coming: a camera starting up or running. A camera
  /// that is blocked, busy or unplugged will not send one, and a black box
  /// waiting for it would only hide the sentence that says why.
  bool get expectsPicture =>
      state == CameraWedgeState.starting || state == CameraWedgeState.running;

  CameraWedgeHealth copyWith({
    CameraWedgeState? state,
    CameraWedgeFault? fault,
    String? detail,
    String? deviceLabel,
    int? width,
    int? height,
    double? fps,
    String? pixelFormat,
    bool? substitutedDevice,
    Duration? retryIn,
    CameraWedgeStats? stats,
    CameraWedgeScan? lastScan,
    DateTime? lastScanAt,
  }) {
    return CameraWedgeHealth(
      state: state ?? this.state,
      fault: fault ?? this.fault,
      detail: detail ?? this.detail,
      deviceLabel: deviceLabel ?? this.deviceLabel,
      width: width ?? this.width,
      height: height ?? this.height,
      fps: fps ?? this.fps,
      pixelFormat: pixelFormat ?? this.pixelFormat,
      substitutedDevice: substitutedDevice ?? this.substitutedDevice,
      retryIn: retryIn ?? this.retryIn,
      stats: stats ?? this.stats,
      lastScan: lastScan ?? this.lastScan,
      lastScanAt: lastScanAt ?? this.lastScanAt,
    );
  }
}

/// One preview frame: 8-bit grey, row-major, `width * height` bytes.
@immutable
class CameraWedgePreviewFrame {
  const CameraWedgePreviewFrame({
    required this.width,
    required this.height,
    required this.luma,
  });

  final int width;
  final int height;
  final Uint8List luma;
}
