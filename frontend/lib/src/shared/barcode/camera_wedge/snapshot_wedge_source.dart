import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';

import 'camera_wedge_policy.dart';
import 'camera_wedge_source.dart';
import 'snapshot_decoder.dart';

/// How the wedge turns one still into one reading. Injected in tests, which
/// must never spawn a worker isolate or go looking for zxing's native library.
typedef SnapshotDecoder =
    Future<SnapshotDecode> Function(String path, {required int maxSize});

/// A camera wedge for the platforms with no live frame stream — which is the
/// one that matters, because the tills are Windows.
///
/// `camera_windows` is the Flutter team's own implementation and the only way
/// to reach a UVC camera there, but it has no image stream:
///
///     throw UnimplementedError('Streaming is not currently supported on Windows')
///     — camera_windows/lib/camera_windows.dart
///
/// So this takes stills in a loop instead and hands each one to **zxing-cpp**
/// through `flutter_zxing`. That is the same engine the backend already runs
/// (`apps/companion/decoding.py`) and the same one `tools/camera-wedge-lab`
/// measured, so everything the lab found — the 12% checksum-passing misread
/// rate that [CameraWedgePolicy] exists to defeat, the rotation behaviour —
/// transfers exactly rather than approximately.
///
/// **What the first version of this class got wrong**, all of it on the same
/// theme — that a still is far more expensive than it looks:
///
///  1. It decoded on the UI isolate. `flutter_zxing`'s file path is a
///     pure-Dart JPEG decode, a pure-Dart resize, a full-frame RGB copy and
///     then a *synchronous* FFI call. One of those lands about every second
///     and holds the isolate for a large fraction of it, so the till stops
///     redrawing for as long as the camera is on. Now in a worker — see
///     [SnapshotDecoder].
///  2. It left the preview running. `initializeCamera` starts one
///     unconditionally, and every frame of it was being converted to RGB32,
///     memcpy'd (~3.7MB at 720p) and pushed at the Flutter engine through
///     `MarkTextureFrameAvailable` — which schedules a frame — for a texture
///     no widget has ever painted. Paused immediately after opening, which
///     makes `camera_windows` drop each sample before the copy
///     (`IsReadyForSample`) while photo capture carries on through its own
///     sink.
///  3. It never deleted the stills, and they do not go to a temp directory:
///     `camera_windows` writes them to the user's **Pictures** folder.
///  4. It let `flutter_zxing` shrink every still to 768px, which is below what
///     a 1-D barcode survives at the resolution these stills arrive in.
///  5. It swallowed every error in the loop, so a camera that opened but could
///     not take a single picture looked exactly like a camera watching an
///     empty counter. That is how one went a whole shift saying it worked.
///
/// Stills are still slower than the ~80 attempts/second the same decoder
/// manages off a live stream, and the difference lands where it can be
/// afforded: a 2-D code is Reed-Solomon protected and believed on one good
/// read, so a payment terminal's receipt QR — the thing the counter wedge
/// cannot read at all — resolves on the first still that comes out sharp. A
/// 1-D barcode needs two agreeing looks, which is why [lookInterval] is
/// published: the policy's agreement window has to be sized for the cadence a
/// backend can actually deliver, not for a live stream's.
class SnapshotWedgeSource implements CameraWedgeSource {
  SnapshotWedgeSource({
    this.interval = Duration.zero,
    this.maxDecodeSize = 1600,
    CameraPlatform? platform,
    SnapshotDecoder? decoder,
  }) : _platform = platform ?? CameraPlatform.instance,
       _decoder = decoder ?? decodeSnapshot;

  /// An extra breather between stills, on top of what a capture costs.
  ///
  /// Zero by default, and that is not greed: `takePicture` on Windows is
  /// itself a few hundred milliseconds, the decode now happens on another
  /// isolate, and the preview is paused — so the loop is already mostly
  /// waiting. The old 250ms was added on top of a *blocking* decode, where it
  /// helped nothing and pushed the gap between two looks past the window in
  /// which the policy is willing to call them agreement.
  final Duration interval;

  /// The longest edge a still is shrunk to before decoding. See
  /// `snapshot_decoder_io.dart` for why the package default of 768 cannot read
  /// a retail barcode off a full-resolution photo.
  final int maxDecodeSize;

  final CameraPlatform _platform;
  final SnapshotDecoder _decoder;
  final _readings = StreamController<CameraWedgeReading>.broadcast();

  int? _cameraId;
  bool _running = false;
  Future<void>? _loop;

  /// Roughly how far apart two looks land on this backend.
  ///
  /// A capture and a decode now overlap, so the cadence is whichever of them
  /// is slower rather than their sum — but on a till that is still close to a
  /// second, against the ~12ms a live stream manages. [CameraWedgeController]
  /// reads this to size the policy's agreement window, because a window that
  /// fits a live stream makes every 1-D barcode on this backend impossible to
  /// confirm rather than merely slow.
  static const Duration lookInterval = Duration(milliseconds: 900);

  /// The last thing that went wrong, whether opening the camera or reading a
  /// still. Null once a still comes back cleanly.
  Object? get lastError => _lastError;
  Object? _lastError;

  /// Stills asked for, and stills that produced neither a code nor a failure.
  /// Both are shown in settings: a camera returning pictures with nothing in
  /// them is aimed wrong, and a camera returning nothing at all is broken, and
  /// they are not the same call to support.
  int get stillsTaken => _stillsTaken;
  int _stillsTaken = 0;

  int get stillsFailed => _stillsFailed;
  int _stillsFailed = 0;

  /// Set when a camera was picked in settings and is not here any more, so the
  /// wedge fell back to another one. The till keeps trading; it just must not
  /// do it silently, because reading off the camera facing the cashier instead
  /// of the one on the stand is the whole feature failing.
  bool get substitutedDevice => _substitutedDevice;
  bool _substitutedDevice = false;

  @override
  Stream<CameraWedgeReading> get readings => _readings.stream;

  @override
  Future<List<CameraWedgeDevice>> devices() async {
    try {
      final cameras = await _platform.availableCameras();
      return CameraWedgeDevice.disambiguated([
        for (final camera in cameras)
          CameraWedgeDevice.fromPlatformName(camera.name),
      ]);
    } on Object {
      // A machine with no camera is not an error state; it is a machine with
      // no camera, and the setting simply offers nothing to pick.
      return const [];
    }
  }

  @override
  Future<void> start({String? deviceId}) async {
    if (_running) return;
    final cameras = await _platform.availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No camera on this machine.');
    }
    final chosen = cameras.firstWhere(
      (camera) => camera.name == deviceId,
      // A shop that has not picked, or that unplugged the one it picked and
      // put back a different one, gets the first camera rather than nothing.
      orElse: () => cameras.first,
    );
    _substitutedDevice = deviceId != null && chosen.name != deviceId;

    final cameraId = await _createCamera(chosen);
    await _platform.initializeCamera(cameraId);
    // The preview is started by initializeCamera whether or not anything will
    // ever paint it, and nothing here ever will: the point of the feature is
    // that nobody looks at the camera. Pausing it stops `camera_windows`
    // converting, copying and publishing ~30 frames a second at the Flutter
    // engine, which is a frame scheduled per camera frame for a texture that
    // is not in the tree. Photo capture uses a different sink and is
    // unaffected.
    await _pausePreview(cameraId);
    _cameraId = cameraId;
    _running = true;
    _lastError = null;
    _loop = _pump();
  }

  /// Open the camera, preferring a capped preview and settling for whatever
  /// the device offers.
  ///
  /// The preset only ever constrained the *preview* — photos are taken at the
  /// sensor's full resolution regardless — and a camera with no mode under the
  /// cap at 15fps or better fails to open at all, because
  /// `FindBaseMediaTypesForSource` needs a preview media type before it will
  /// return success. Since the preview is paused a moment later, a cap is
  /// worth having and not worth failing over.
  Future<int> _createCamera(CameraDescription camera) async {
    try {
      return await _platform.createCameraWithSettings(
        camera,
        const MediaSettings(
          resolutionPreset: ResolutionPreset.high,
          enableAudio: false,
        ),
      );
    } on Object catch (error) {
      _lastError = error;
      return await _platform.createCameraWithSettings(
        camera,
        const MediaSettings(
          resolutionPreset: ResolutionPreset.max,
          enableAudio: false,
        ),
      );
    }
  }

  Future<void> _pausePreview(int cameraId) async {
    try {
      await _platform.pausePreview(cameraId);
    } on Object {
      // A platform that will not pause its preview still scans; it just costs
      // more to do it. Not worth refusing to start over.
    }
  }

  /// Capture and decode, pipelined.
  ///
  /// The decode of one still is started and deliberately *not* awaited, so it
  /// runs on its worker while the next picture is being taken; the previous
  /// one is collected straight afterwards, by which point it has had a whole
  /// capture to finish in. The cadence is therefore whichever of capture and
  /// decode is slower rather than the two added together — which is the
  /// difference between a 1-D barcode being slow and it being impossible.
  ///
  /// Readings are still emitted in the order the pictures were taken, and
  /// stamped with when the shutter went rather than when the worker replied,
  /// because the policy judges agreement by how far apart two looks at the
  /// counter were.
  Future<void> _pump() async {
    Future<SnapshotDecode>? pending;
    DateTime? pendingAt;

    Future<void> collect() async {
      final inFlight = pending;
      final at = pendingAt;
      pending = null;
      pendingAt = null;
      if (inFlight == null || at == null) return;
      final decode = await inFlight;
      if (decode.isFailure) {
        _lastError = decode.error;
        _stillsFailed += 1;
        return;
      }
      _lastError = null;
      if (!decode.isRead || !_running) return;
      _readings.add(
        CameraWedgeReading(
          value: decode.value!,
          symbology: decode.symbology ?? 'unknown',
          at: at,
        ),
      );
    }

    while (_running) {
      final cameraId = _cameraId;
      if (cameraId == null) break;
      final takenAt = DateTime.now();
      String? path;
      try {
        _stillsTaken += 1;
        path = (await _platform.takePicture(cameraId)).path;
      } on Object catch (error) {
        // A camera unplugged mid-shift must not take the till down with it, so
        // the loop keeps asking until stop() says otherwise — but it says what
        // happened rather than pretending nothing did.
        _lastError = error;
        _stillsFailed += 1;
      }
      final next = path == null ? null : _decoder(path, maxSize: maxDecodeSize);
      await collect();
      pending = next;
      pendingAt = takenAt;
      if (!_running) break;
      if (interval > Duration.zero) {
        await Future<void>.delayed(interval);
      } else if (path == null) {
        // Nothing was captured, so nothing is overlapping the next attempt.
        // Without a breather a camera that is failing would spin as fast as
        // the error comes back.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    await collect();
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _loop;
    _loop = null;
    final cameraId = _cameraId;
    _cameraId = null;
    if (cameraId != null) {
      try {
        await _platform.dispose(cameraId);
      } on Object {
        // Already gone. Releasing a camera twice is not worth a crash.
      }
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _readings.close();
  }
}
