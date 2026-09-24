import 'dart:typed_data';

/// What the native wedge reports, decoded from the Lists it posts to its port.
///
/// The layouts are defined once, in `src/include/pointy_camera_wedge.h`, next
/// to the `PCW_MSG_*` kinds; the parsing here mirrors them field for field.
/// Anything that does not match — a bare integer liveness probe, a message
/// from a newer library — parses to null and is ignored rather than trusted.
sealed class NativeWedgeEvent {
  const NativeWedgeEvent();

  static const int _status = 1;
  static const int _scan = 2;
  static const int _stats = 3;
  static const int _preview = 4;

  static NativeWedgeEvent? parse(Object? message) {
    if (message is! List || message.isEmpty) return null;
    try {
      switch (message[0]) {
        case _status:
          return NativeWedgeStatus._fromMessage(message);
        case _scan:
          return NativeWedgeScan._fromMessage(message);
        case _stats:
          return NativeWedgeStats._fromMessage(message);
        case _preview:
          return NativeWedgePreview._fromMessage(message);
      }
    } on Object {
      // A malformed message is dropped, not allowed to take the stream down.
    }
    return null;
  }
}

/// The wedge's lifecycle (PCW_STATE_*).
enum NativeWedgeState {
  starting,
  running,
  recovering,
  stopped;

  static NativeWedgeState fromCode(int code) => switch (code) {
        1 => starting,
        2 => running,
        3 => recovering,
        _ => stopped,
      };
}

/// Why a camera is not running (PCW_ERROR_*). Unknown codes read as
/// [platform], which the app words as "could not start the camera".
enum NativeWedgeError {
  none,
  noCamera,
  deviceNotFound,
  accessDenied,
  inUse,
  deviceLost,
  noUsableFormat,
  stalled,
  platform,
  unsupported;

  static NativeWedgeError fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : platform;
}

/// PCW_MSG_STATUS.
final class NativeWedgeStatus extends NativeWedgeEvent {
  const NativeWedgeStatus({
    required this.state,
    this.error = NativeWedgeError.none,
    this.message = '',
    this.deviceId = '',
    this.deviceLabel = '',
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.pixelFormat = '',
    this.substituted = false,
    this.retryIn = Duration.zero,
  });

  factory NativeWedgeStatus._fromMessage(List<Object?> m) => NativeWedgeStatus(
        state: NativeWedgeState.fromCode(m[1]! as int),
        error: NativeWedgeError.fromCode(m[2]! as int),
        message: m[3]! as String,
        deviceId: m[4]! as String,
        deviceLabel: m[5]! as String,
        width: m[6]! as int,
        height: m[7]! as int,
        fps: (m[8]! as int) / 1000,
        pixelFormat: m[9]! as String,
        substituted: m[10] == 1,
        retryIn: Duration(milliseconds: m[11]! as int),
      );

  final NativeWedgeState state;
  final NativeWedgeError error;

  /// Raw detail (an HRESULT, the step that failed). For logs and support,
  /// never shown to a cashier as it is.
  final String message;
  final String deviceId;
  final String deviceLabel;
  final int width;
  final int height;
  final double fps;

  /// "MJPG>NV12" when the camera sends one format and it is decoded to
  /// another.
  final String pixelFormat;

  /// The picked camera was absent and the only other one is being used.
  final bool substituted;

  /// When [state] is recovering: how long until the next attempt.
  final Duration retryIn;
}

/// PCW_MSG_SCAN: a read the native confirmation policy stands behind.
final class NativeWedgeScan extends NativeWedgeEvent {
  const NativeWedgeScan({
    required this.text,
    required this.symbology,
    required this.confirmations,
  });

  factory NativeWedgeScan._fromMessage(List<Object?> m) => NativeWedgeScan(
        text: m[1]! as String,
        symbology: m[2]! as String,
        confirmations: m[3]! as int,
      );

  final String text;
  final String symbology;
  final int confirmations;
}

/// PCW_MSG_STATS: counters, posted about once a second while running.
final class NativeWedgeStats extends NativeWedgeEvent {
  const NativeWedgeStats({
    this.framesCaptured = 0,
    this.framesDecoded = 0,
    this.decodeHits = 0,
    this.scans = 0,
    this.rejectedDisagreements = 0,
    this.suppressedRereads = 0,
    this.captureFps = 0,
    this.decodeMilliseconds = 0,
    this.active = false,
  });

  factory NativeWedgeStats._fromMessage(List<Object?> m) => NativeWedgeStats(
        framesCaptured: m[1]! as int,
        framesDecoded: m[2]! as int,
        decodeHits: m[3]! as int,
        scans: m[4]! as int,
        rejectedDisagreements: m[5]! as int,
        suppressedRereads: m[6]! as int,
        captureFps: (m[7]! as int) / 1000,
        decodeMilliseconds: (m[8]! as int) / 1000,
        active: m[9] == 1,
      );

  final int framesCaptured;
  final int framesDecoded;
  final int decodeHits;
  final int scans;

  /// Reads thrown away because a second look disagreed: each one a wrong
  /// product that did not reach a cart.
  final int rejectedDisagreements;
  final int suppressedRereads;
  final double captureFps;

  /// Average time of one decode pass over the last interval.
  final double decodeMilliseconds;

  /// Decoding every frame (something moved or was read recently) rather than
  /// idling at a few frames a second.
  final bool active;
}

/// PCW_MSG_PREVIEW: the newest frame, grey, shrunk, row-major.
final class NativeWedgePreview extends NativeWedgeEvent {
  const NativeWedgePreview({
    required this.width,
    required this.height,
    required this.luma,
  });

  factory NativeWedgePreview._fromMessage(List<Object?> m) {
    final width = m[1]! as int;
    final height = m[2]! as int;
    final luma = m[3]! as Uint8List;
    if (width <= 0 || height <= 0 || luma.length != width * height) {
      throw const FormatException('preview size does not match its pixels');
    }
    return NativeWedgePreview(width: width, height: height, luma: luma);
  }

  final int width;
  final int height;
  final Uint8List luma;
}

/// A camera the OS can see.
class NativeCameraDevice {
  const NativeCameraDevice({required this.id, required this.label});

  /// Whatever the native side needs to find it again (a Media Foundation
  /// symbolic link on Windows). Never shown.
  final String id;
  final String label;
}

/// PCW_MSG_DEVICES, the reply to a device listing.
class NativeDeviceList {
  const NativeDeviceList({
    required this.devices,
    this.error = NativeWedgeError.none,
    this.message = '',
  });

  static NativeDeviceList? parse(Object? message) {
    if (message is! List || message.length < 4 || message[0] != 5) return null;
    try {
      final flat = (message[3]! as List).cast<String>();
      return NativeDeviceList(
        error: NativeWedgeError.fromCode(message[1]! as int),
        message: message[2]! as String,
        devices: [
          for (var i = 0; i + 1 < flat.length; i += 2)
            NativeCameraDevice(id: flat[i], label: flat[i + 1]),
        ],
      );
    } on Object {
      return null;
    }
  }

  final List<NativeCameraDevice> devices;
  final NativeWedgeError error;
  final String message;
}
