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

  bool get hasDevice => devices.isNotEmpty;
  bool get isPaused => devices.isNotEmpty && devices.every((d) => d.isPaused);
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
    this.deviceRefreshInterval = const Duration(minutes: 2),
    this.retryBackoff = const Duration(milliseconds: 250),
    this.streamRetryInterval = const Duration(minutes: 1),
  }) : _repository = repository;

  final CompanionRepository _repository;
  final String tillKey;
  final Duration pollInterval;
  final Duration deviceRefreshInterval;

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
    await refreshDevices();
    _deviceTimer = Timer.periodic(
      deviceRefreshInterval,
      (_) => refreshDevices(),
    );
  }

  /// Hold the channel open even with no phone paired — while the pairing sheet
  /// is on screen, so the till reacts the moment a phone joins.
  void boost() {
    if (_disposed) return;
    _boosted = true;
    _ensureTransport();
  }

  void endBoost() {
    _boosted = false;
    _ensureTransport();
  }

  Future<void> refreshDevices() async {
    if (_disposed) return;
    final result = await _repository.loadDevices(tillKey);
    if (_disposed) return;
    if (result case Ok(value: final devices)) {
      status.value = status.value.copyWith(devices: devices);
      _ensureTransport();
    }
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
    unawaited(_scans.close());
    unawaited(_events.close());
    status.dispose();
  }
}
