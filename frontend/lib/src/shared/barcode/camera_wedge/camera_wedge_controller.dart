import 'dart:async';

import 'package:flutter/foundation.dart';

import '../camera_scanning_support.dart';
import 'camera_wedge_policy.dart';
import 'camera_wedge_source.dart';
import 'mobile_scanner_wedge_source.dart';
import 'snapshot_wedge_source.dart';

/// One camera acting as a barcode wedge for this till.
///
/// Owns a [CameraWedgeSource] (the plumbing, which differs per platform) and a
/// [CameraWedgePolicy] (the rules, which do not), and publishes only the scans
/// the policy will stand behind. From a screen's point of view this is exactly
/// the counter scanner: a stream of strings, same handler, same gating — the
/// shape `CompanionScanListener` already established for a paired phone.
///
/// It is deliberately not a `ChangeNotifier` around the camera preview. The
/// point of the feature is that nobody looks at the camera: it hovers over the
/// counter, and things are read by being put down.
class CameraWedgeController extends ChangeNotifier {
  CameraWedgeController({CameraWedgeSource? source, CameraWedgePolicy? policy})
    : _source = source ?? _sourceForThisPlatform(),
      _policy = policy ?? _policyForThisPlatform();

  /// A policy sized for the cadence the backend can actually deliver.
  ///
  /// The window is how far apart two looks may be and still count as
  /// corroboration, and its default was chosen for a live stream: at the ~80
  /// attempts/second the lab measured, honest agreement arrives in tens of
  /// milliseconds and 600ms is generous. The snapshot backend delivers a look
  /// roughly once a second, so under that default **no 1-D barcode could ever
  /// be confirmed** — two agreeing looks were required and two looks could
  /// never land close enough together. The feature reported itself as running
  /// and read nothing but QR codes, which is precisely what a shop saw.
  ///
  /// Widening it costs almost nothing: the window guards against an item being
  /// swapped between two looks, and a swap does not produce agreement — it
  /// produces two different values, which is the case the guard already
  /// counts and rejects.
  static CameraWedgePolicy _policyForThisPlatform() => switch (backend) {
    CameraWedgeBackend.snapshot => CameraWedgePolicy(
      agreementWindow: SnapshotWedgeSource.lookInterval * 3,
    ),
    _ => CameraWedgePolicy(),
  };

  final CameraWedgeSource? _source;
  final CameraWedgePolicy _policy;

  StreamSubscription<CameraWedgeReading>? _subscription;
  final _scans = StreamController<CameraWedgeScan>.broadcast();

  bool _isRunning = false;
  Object? _failure;

  /// Confirmed scans, in the order a till should act on them.
  Stream<CameraWedgeScan> get scans => _scans.stream;

  bool get isRunning => _isRunning;

  /// Why the camera is not running, when it should be — or why it is running
  /// and reading nothing. Surfaced in settings so a refused permission reads
  /// as a refused permission rather than as a feature that does nothing.
  ///
  /// Covers both halves on purpose. A camera that never opened and a camera
  /// that opened and then failed every single still are different faults with
  /// the same symptom, and the second one used to be invisible: the loop
  /// swallowed its errors and the settings page said the wedge was running.
  Object? get failure => _failure ?? _sourceFailure;

  Object? get _sourceFailure {
    final source = _source;
    return source is SnapshotWedgeSource ? source.lastError : null;
  }

  /// Whether this platform can run a camera wedge at all, and how.
  ///
  /// `mobile_scanner` where it exists; stills through zxing-cpp on the
  /// desktops where it does not — which is where the tills are. Every platform
  /// Pointy ships on now has one or the other, so `none` describes a future
  /// platform rather than a gap.
  static CameraWedgeBackend get backend {
    if (cameraScanningSupported) return CameraWedgeBackend.platformScanner;
    if (kIsWeb) return CameraWedgeBackend.none;
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.linux => CameraWedgeBackend.snapshot,
      _ => CameraWedgeBackend.none,
    };
  }

  static CameraWedgeSource? _sourceForThisPlatform() => switch (backend) {
    CameraWedgeBackend.platformScanner => MobileScannerWedgeSource(),
    CameraWedgeBackend.snapshot => SnapshotWedgeSource(),
    CameraWedgeBackend.none => null,
  };

  /// What the guard has thrown away this session: disagreeing reads (each one
  /// a wrong product that did not reach a cart) and re-reads of an item still
  /// sitting under the camera.
  int get rejectedDisagreements => _policy.rejectedDisagreements;
  int get suppressedRereads => _policy.suppressedRereads;

  Future<List<CameraWedgeDevice>> devices() async =>
      await _source?.devices() ?? const [];

  Future<void> start({String? deviceId}) async {
    final source = _source;
    if (source == null || _isRunning) return;
    _failure = null;
    _policy.reset();
    _subscription = source.readings.listen(_onReading);
    try {
      await source.start(deviceId: deviceId);
      _isRunning = true;
    } catch (error) {
      // A camera in use by something else, or a permission the shop declined.
      // The till keeps trading; the wedge simply is not there.
      _failure = error;
      await _subscription?.cancel();
      _subscription = null;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _source?.stop();
    _policy.reset();
    _isRunning = false;
    notifyListeners();
  }

  void _onReading(CameraWedgeReading reading) {
    final scan = _policy.offer(reading);
    if (scan != null) _scans.add(scan);
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _source?.dispose();
    await _scans.close();
    super.dispose();
  }
}
