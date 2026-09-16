import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/result.dart';
import '../../data/models/companion.dart';
import '../../data/repositories/companion_repository.dart';
import '../../data/services/api_session.dart';

/// How the till is currently hearing from its phone.
enum CompanionLinkState {
  /// No phone is paired; nothing is held open.
  idle,

  /// Opening or re-opening the event stream.
  connecting,

  /// Live: scans arrive as they happen.
  live,

  /// The stream keeps failing, so the till is polling instead. Slower, but a
  /// scan still lands — this is a degraded mode, never a dead one.
  polling,
}

/// A snapshot the UI can render without knowing anything about transports.
class CompanionStatus {
  const CompanionStatus({
    this.state = CompanionLinkState.idle,
    this.devices = const [],
  });

  final CompanionLinkState state;
  final List<CompanionDevice> devices;

  /// The phones that can still act.
  ///
  /// A device whose register session closed, or that has been idle past its
  /// expiry, stays in [devices] on purpose — the pairing sheet says so rather
  /// than pretending the phone was never there — but it cannot scan, so nothing
  /// should hold a transport open for it or offer to photograph with it.
  Iterable<CompanionDevice> get liveDevices => devices.where((d) => d.isLive);

  bool get hasDevice => devices.any((d) => d.isLive);

  bool get isPaused {
    final live = liveDevices.toList();
    return live.isNotEmpty && live.every((d) => d.isPaused);
  }

  bool get isConnected =>
      state == CompanionLinkState.live || state == CompanionLinkState.polling;

  CompanionStatus copyWith({
    CompanionLinkState? state,
    List<CompanionDevice>? devices,
  }) {
    return CompanionStatus(
      state: state ?? this.state,
      devices: devices ?? this.devices,
    );
  }
}

/// Keeps this till connected to its paired phone, and turns what the phone
/// reads into an ordinary scan.
///
/// The design rule that matters: a companion scan is delivered through
/// [scans], which POS, purchasing and stock count feed into the *same*
/// callback their USB wedge scanner already uses. None of those screens knows
/// a companion exists — which is why pairing a phone makes every scanning
/// surface in the app work at once, and why a change here cannot break them.
///
/// Nothing is held open when no phone is paired: a shop that never uses the
/// feature pays nothing for it. The stream opens when a device pairs (or while
/// the pairing sheet is on screen, so the till sees the phone arrive), and
/// closes again when the last one leaves.
class CompanionBridge {
  CompanionBridge({
    required CompanionRepository repository,
    required this.tillKey,
    this.pollInterval = const Duration(seconds: 2),
    this.pairingRefreshInterval = const Duration(seconds: 15),
    this.pairedRefreshInterval = const Duration(minutes: 15),
    this.retryBackoff = const Duration(milliseconds: 250),
    this.streamRetryInterval = const Duration(minutes: 1),
  }) : _repository = repository;

  final CompanionRepository _repository;
  final String tillKey;
  final Duration pollInterval;

  /// How often to re-read the roster while the pairing sheet is open.
  ///
  /// Short, because a person is watching a QR code that expires in two minutes
  /// and this is the one moment where a missed update is the feature failing in
  /// front of them. It costs about eight requests per pairing attempt, spent
  /// only while somebody is actually waiting for a phone to appear.
  final Duration pairingRefreshInterval;

  /// How often to re-read it while a phone is paired.
  ///
  /// The one state where a refresh still learns something the event stream
  /// cannot tell it. A device whose register session closed, or that has been
  /// idle past its expiry, stops being live on the server with nothing emitted:
  /// the revocation is lazy and happens when the *phone* next calls, but
  /// ``is_live`` is computed per response, so asking is how the till finds out.
  /// Fifteen minutes because those are shift-scale events.
  final Duration pairedRefreshInterval;

  /// Multiplied by the consecutive-failure count between stream attempts.
  final Duration retryBackoff;

  /// How long to stay on polling before trying the live stream again. Long
  /// enough that a genuinely broken stream — a proxy that buffers SSE, say —
  /// is not retried every couple of seconds for the rest of the shift.
  final Duration streamRetryInterval;

  final ValueNotifier<CompanionStatus> status = ValueNotifier(
    const CompanionStatus(),
  );

  final StreamController<String> _scans = StreamController<String>.broadcast();
  final StreamController<CompanionEvent> _events =
      StreamController<CompanionEvent>.broadcast();

  /// Barcode and QR payloads, ready to hand to the same callback a USB wedge
  /// scanner feeds.
  Stream<String> get scans => _scans.stream;

  /// Everything the phone sent, including photos — for screens that care about
  /// captures rather than codes.
  Stream<CompanionEvent> get events => _events.stream;

  StreamSubscription<SseEvent>? _subscription;
  Timer? _pollTimer;
  Timer? _deviceTimer;
  Duration? _deviceInterval;
  Timer? _retryTimer;
  int _cursor = 0;
  int _failures = 0;
  DateTime? _pollingSince;
  bool _started = false;
  bool _boosted = false;
  bool _disposed = false;

  /// Give up on the live stream after this many consecutive failures and poll
  /// instead. Three is enough to ride out a backend restart without a cashier
  /// noticing, and few enough that a genuinely broken stream degrades fast.
  static const int _failuresBeforePolling = 3;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    // One read, and then only as much polling as there is something to see —
    // `refreshDevices` schedules that for us.
    await refreshDevices();
  }

  /// Hold the channel open even with no phone paired — while the pairing sheet
  /// is on screen, so the till reacts the moment a phone joins.
  void boost() {
    if (_disposed) return;
    _boosted = true;
    _ensureTransport();
    _ensureDeviceRefresh();
  }

  void endBoost() {
    _boosted = false;
    _ensureTransport();
    _ensureDeviceRefresh();
  }

  Future<void> refreshDevices() async {
    if (_disposed) return;
    final result = await _repository.loadDevices(tillKey);
    if (_disposed) return;
    if (result case Ok(value: final devices)) {
      status.value = status.value.copyWith(devices: devices);
      _ensureTransport();
      _ensureDeviceRefresh();
    }
  }

  // -- how often to ask ------------------------------------------------------

  /// How often the roster is worth re-reading, or ``null`` for "not at all".
  ///
  /// The rule is that a poll has to be able to *see* something. The roster can
  /// only grow through a pairing this till created — a single-use code, alive
  /// for two minutes, issued from the pairing sheet — and that arrives as a
  /// `device_state` frame on the stream the sheet holds open. So with no phone
  /// paired and no sheet on screen there is nothing a request could discover,
  /// and the honest number of requests is zero.
  ///
  /// It was two minutes in every state, forever. One shop's week: **9,481
  /// polls, one pairing** — and between 03:00 and 07:00, with the shop shut and
  /// the tills idle, those polls were 100% of the backend's traffic.
  Duration? _wantedRefreshInterval() {
    if (_disposed) return null;
    if (status.value.hasDevice) return pairedRefreshInterval;
    if (_boosted) return pairingRefreshInterval;
    return null;
  }

  void _ensureDeviceRefresh() {
    final wanted = _wantedRefreshInterval();
    // Unchanged is the common case — `refreshDevices` runs this on every tick —
    // and rescheduling then would reset the clock on every pass and starve the
    // timer it is supposed to be keeping.
    if (wanted == _deviceInterval) return;
    _deviceTimer?.cancel();
    _deviceTimer = null;
    _deviceInterval = wanted;
    if (wanted == null) return;
    _deviceTimer = Timer.periodic(wanted, (_) => refreshDevices());
  }

  // -- transport ------------------------------------------------------------

  void _ensureTransport() {
    final wanted = _boosted || status.value.hasDevice;
    if (!wanted) {
      _teardownTransport();
      _setState(CompanionLinkState.idle);
      return;
    }
    if (_subscription != null || _pollTimer != null || _retryTimer != null) {
      return;
    }
    if (_failures >= _failuresBeforePolling) {
      _startPolling();
    } else {
      _openStream();
    }
  }

  void _openStream() {
    _setState(CompanionLinkState.connecting);
    _subscription = _repository
        .openStream(tillKey: tillKey, since: _cursor)
        .listen(
          _onFrame,
          onError: (Object error) => _onStreamClosed(failed: true),
          onDone: () => _onStreamClosed(failed: false),
          cancelOnError: true,
        );
  }

  void _onFrame(SseEvent frame) {
    switch (frame.event) {
      case 'ready':
      case 'ping':
        _failures = 0;
        _setState(CompanionLinkState.live);
      case 'reconnect':
        // The backend bounds every stream's life so nothing lives for days.
        // A planned reconnect is not a failure and must not count as one.
        _cursorFrom(frame.data);
        _restartStream(delay: Duration.zero);
      case 'companion':
        _failures = 0;
        _setState(CompanionLinkState.live);
        _dispatch(frame.data);
      default:
        break;
    }
  }

  void _onStreamClosed({required bool failed}) {
    _subscription = null;
    if (_disposed || !(_boosted || status.value.hasDevice)) {
      _setState(CompanionLinkState.idle);
      return;
    }
    if (failed) _failures++;
    if (_failures >= _failuresBeforePolling) {
      _startPolling();
      return;
    }
    _restartStream(delay: retryBackoff * _failures);
  }

  void _restartStream({required Duration delay}) {
    _subscription?.cancel();
    _subscription = null;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_disposed) return;
      _ensureTransport();
    });
  }

  void _startPolling() {
    if (_pollTimer != null) return;
    _setState(CompanionLinkState.polling);
    _pollingSince = DateTime.now();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    final result = await _repository.loadEvents(
      tillKey: tillKey,
      since: _cursor,
    );
    if (_disposed) return;
    if (result case Ok(value: final page)) {
      _cursor = page.cursor > _cursor ? page.cursor : _cursor;
      for (final event in page.events) {
        _emit(event);
      }
      _maybeLeavePolling();
    }
  }

  /// Polling is a fallback, not a destination — but going back to the stream on
  /// the first successful poll would ping-pong forever against a stream that is
  /// permanently broken. So retry it on a timer instead, and keep polling (and
  /// keep delivering scans) in between.
  void _maybeLeavePolling() {
    final since = _pollingSince;
    if (since == null) return;
    if (DateTime.now().difference(since) < streamRetryInterval) return;
    _pollingSince = null;
    _failures = 0;
    _pollTimer?.cancel();
    _pollTimer = null;
    _ensureTransport();
  }

  void _teardownTransport() {
    _subscription?.cancel();
    _subscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollingSince = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  // -- events ---------------------------------------------------------------

  void _dispatch(String data) {
    final decoded = _decode(data);
    if (decoded == null) return;
    _emit(CompanionEvent.fromJson(decoded));
  }

  void _cursorFrom(String data) {
    final decoded = _decode(data);
    final cursor = decoded?['cursor'];
    if (cursor is int && cursor > _cursor) _cursor = cursor;
  }

  Map<String, Object?>? _decode(String data) {
    if (data.isEmpty) return null;
    try {
      final decoded = jsonDecode(data);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void _emit(CompanionEvent event) {
    if (event.id > _cursor) _cursor = event.id;
    if (!_events.isClosed) _events.add(event);

    switch (event.kind) {
      case CompanionEventKind.scan:
        final value = event.scannedValue;
        if (value.isNotEmpty && !_scans.isClosed) _scans.add(value);
      case CompanionEventKind.deviceState:
        // A phone joining or leaving changes whether we should be connected at
        // all, so re-read the roster rather than guess from the event.
        unawaited(refreshDevices());
      case CompanionEventKind.capture:
      case CompanionEventKind.unknown:
        break;
    }
  }

  void _setState(CompanionLinkState state) {
    if (_disposed || status.value.state == state) return;
    status.value = status.value.copyWith(state: state);
  }

  void dispose() {
    _disposed = true;
    _started = false;
    _teardownTransport();
    _deviceTimer?.cancel();
    _deviceTimer = null;
    _deviceInterval = null;
    unawaited(_scans.close());
    unawaited(_events.close());
    status.dispose();
  }
}
