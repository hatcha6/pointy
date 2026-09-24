/// What a camera is allowed to hand the till, and how sure it has to be.
///
/// A camera is not a scanner. A scanner reads a code with dedicated optics and
/// reports it once; a camera reads a *picture* of a code, tens of times a
/// second, and some of those reads are wrong. Measured on a real product with
/// zxing-cpp (`tools/camera-wedge-lab`), one EAN-13 came back as three
/// different wrong values in 24 scans — **12%** — and every wrong value
/// **passed its own check digit**:
///
///     truth    3600523434725
///     read     9660323434725   check digit valid
///     read     0608713434725   check digit valid
///     read     9620723434725   check digit valid
///
/// At a till that is the wrong product at the wrong price with nothing looking
/// amiss on any screen. It is the one failure that would make a shop stop
/// trusting the feature for good, and no amount of speed is worth it.
///
/// So this class exists to turn a stream of guesses into scans a till may act
/// on, and the rule it enforces is that **confidence is bought per symbology,
/// not per camera**.
library;

import 'camera_wedge_symbology.dart';

/// One decode, as a source reported it. Not yet a scan.
class CameraWedgeReading {
  const CameraWedgeReading({
    required this.value,
    required this.symbology,
    this.at,
  });

  final String value;

  /// The symbology name as the decoder spells it (`EAN13`, `QRCode`, …).
  /// Normalised inside [CameraWedgeSymbology]; an unknown name is treated as
  /// the least protected kind, never the most.
  final String symbology;

  /// When it was read. Defaults to the policy's clock, which is what every
  /// caller outside a test wants.
  final DateTime? at;
}

/// A reading the policy is willing to stand behind.
class CameraWedgeScan {
  const CameraWedgeScan({
    required this.value,
    required this.symbology,
    required this.confirmations,
  });

  final String value;
  final String symbology;

  /// How many agreeing reads it took. Carried so telemetry can show whether
  /// the guard is working hard or idling — and so a support call about a slow
  /// camera has a number in it.
  final int confirmations;
}

/// Turns a stream of decoder guesses into scans, or into nothing.
///
/// Stateful and single-threaded by design: it is one camera pointed at one
/// counter. Construct one per running camera and throw it away when it stops.
///
/// The native wedge (`packages/pointy_camera_wedge`,
/// `src/policy/confirmation_policy.cpp`) implements the same rule in C++ for
/// the tills, where decoding happens on the other side of the FFI boundary.
/// Keep the two in step; their tests are case for case.
class CameraWedgePolicy {
  CameraWedgePolicy({
    this.agreementWindow = const Duration(milliseconds: 600),
    this.rereadHoldoff = const Duration(milliseconds: 1500),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How long agreeing reads may be spread over. Two reads further apart than
  /// this are not corroboration — the item may have been swapped for another.
  /// At the ~80 attempts/second the lab measured, honest agreement arrives in
  /// tens of milliseconds, so this is generous on purpose.
  final Duration agreementWindow;

  /// How long the same value is ignored after being emitted. A camera stares
  /// at an item continuously and would otherwise report it forty times a
  /// second; a hardware scanner reads once and holds off, and a till expects
  /// the hardware scanner's behaviour.
  final Duration rereadHoldoff;

  final DateTime Function() _clock;

  String _pendingValue = '';
  String _pendingSymbology = '';
  int _pendingCount = 0;
  DateTime? _pendingAt;

  /// Values already scanned and still in view, with when each was last seen.
  ///
  /// One entry PER VALUE. The first version kept a single "last scanned"
  /// value, and with two codes in view — a product's EAN beside a QR on the
  /// same box — each scan made the other one new again, so the box was rung
  /// up over and over for as long as it sat under the camera.
  final Map<String, DateTime> _held = {};

  /// Readings thrown away because a second look disagreed. Every one of these
  /// is a wrong product that did not reach a cart.
  int get rejectedDisagreements => _rejectedDisagreements;
  int _rejectedDisagreements = 0;

  /// Readings thrown away as a re-read of something already sold.
  int get suppressedRereads => _suppressedRereads;
  int _suppressedRereads = 0;

  /// Offer a reading. Returns the scan to act on, or null to keep looking.
  CameraWedgeScan? offer(CameraWedgeReading reading) => offerAll([reading]);

  /// Offer everything one frame was read as. Returns at most one scan.
  ///
  /// Of the codes not held off, the one already being corroborated is
  /// preferred, so a second code in the picture cannot keep interrupting its
  /// agreement.
  CameraWedgeScan? offerAll(List<CameraWedgeReading> readings) {
    if (readings.isEmpty) return null;
    final now = readings.first.at ?? _clock();

    // A code out of sight for the whole holdoff is a new sale when it comes
    // back; one still in view keeps its hold refreshed below.
    _held.removeWhere((_, seen) => now.difference(seen) >= rereadHoldoff);

    final candidates = <String, CameraWedgeReading>{};
    for (final reading in readings) {
      final value = reading.value.trim();
      if (value.isEmpty) continue;
      if (_held.containsKey(value)) {
        // Still looking at something already sold. Refresh rather than let
        // the hold expire under a stationary item, or a box left on the
        // counter is rung up twice.
        _held[value] = now;
        _suppressedRereads += 1;
        continue;
      }
      candidates.putIfAbsent(value, () => reading);
    }
    if (candidates.isEmpty) return null;

    final value = _pendingCount > 0 && candidates.containsKey(_pendingValue)
        ? _pendingValue
        : candidates.keys.first;
    final reading = candidates[value]!;
    final kind = CameraWedgeSymbology.classify(reading.symbology);
    final needed = kind.requiredAgreement;
    final pendingAt = _pendingAt;
    final withinWindow =
        pendingAt != null && now.difference(pendingAt) <= agreementWindow;

    if (_pendingCount > 0 && withinWindow && value == _pendingValue) {
      _pendingCount += 1;
    } else {
      // A DIFFERENT value inside the window is the misread case, and the only
      // one worth counting: a stale pending entry that simply timed out is an
      // item being taken away, not a decoder being wrong.
      if (_pendingCount > 0 && withinWindow) {
        _rejectedDisagreements += 1;
      }
      _pendingValue = value;
      _pendingSymbology = reading.symbology;
      _pendingCount = 1;
    }
    _pendingAt = now;

    if (_pendingCount < needed) return null;

    final scan = CameraWedgeScan(
      value: value,
      symbology: _pendingSymbology,
      confirmations: _pendingCount,
    );
    _held[value] = now;
    _pendingValue = '';
    _pendingSymbology = '';
    _pendingCount = 0;
    _pendingAt = null;
    return scan;
  }

  /// Forget everything in flight. Called when the camera stops, when the
  /// screen changes, or when a scan has been consumed somewhere the policy
  /// cannot see — so a stale pending reading cannot pair with a fresh one
  /// minutes later.
  void reset() {
    _pendingValue = '';
    _pendingSymbology = '';
    _pendingCount = 0;
    _pendingAt = null;
    _held.clear();
  }
}
