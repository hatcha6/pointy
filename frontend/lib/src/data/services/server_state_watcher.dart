import 'dart:async';

import '../../core/server_state.dart';
import 'server_state_api_client.dart';

/// Keeps an idle till honest.
///
/// Every API response already carries the state vector, so a device that is
/// being used learns what changed from whatever it was already doing. This
/// covers the one case that cannot reach: a POS sitting on the sell screen
/// between customers, sending nothing and receiving nothing, while the manager
/// in the back office changes a price. Without a poll that till shows the old
/// number until someone touches it.
///
/// Deliberately a poll and not a stream: the shop's backend is one process on
/// the LAN, often behind a relay tunnel, and a held-open connection per till is
/// a worker per till plus reconnect logic to get wrong. An unchanged vector
/// answers 304 from Redis with no database work at all, so the steady-state
/// cost of this is a few hundred bytes a minute per device.
class ServerStateWatcher {
  ServerStateWatcher({
    required Future<ServerStateSnapshot> Function() fetchState,
    required ServerStateNotifier state,
    Duration? initialInterval,
  }) : _fetchState = fetchState,
       _state = state,
       _interval =
           initialInterval ??
           const Duration(seconds: defaultServerStatePollSeconds);

  final Future<ServerStateSnapshot> Function() _fetchState;
  final ServerStateNotifier _state;

  /// Backing off on failure matters more here than anywhere else in the app:
  /// this runs forever, on every device, and a backend that is down (or a shop
  /// whose Wi-Fi dropped) must not be asked four times a minute per till.
  static const Duration _maxBackoff = Duration(minutes: 5);

  Duration _interval;
  Duration _backoff = Duration.zero;
  Timer? _timer;
  bool _running = false;
  bool _started = false;
  bool _paused = false;

  /// True once a poll has come back saying the backend publishes versions.
  /// Until then, callers keep trusting their TTLs.
  bool get isServerEnabled => _serverEnabled;
  bool _serverEnabled = false;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _paused = false;
    _backoff = Duration.zero;
    unawaited(pollNow());
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    _serverEnabled = false;
  }

  /// The app went to the background. Stop asking — nobody is looking, and on a
  /// phone the OS will freeze the timer anyway.
  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Back in the foreground: ask immediately rather than waiting out the
  /// interval, because this is exactly when the screen is most likely stale.
  void resume() {
    if (!_started) {
      return;
    }
    _paused = false;
    _backoff = Duration.zero;
    unawaited(pollNow());
  }

  /// One poll, now. Safe to call at any time; overlapping calls collapse.
  Future<void> pollNow() async {
    if (!_started || _running) {
      return;
    }
    _running = true;
    _timer?.cancel();
    _timer = null;
    try {
      final snapshot = await _fetchState();
      _serverEnabled = snapshot.enabled;
      _backoff = Duration.zero;
      if (snapshot.pollIntervalSeconds > 0) {
        // The server sets the cadence, so a struggling shop can be slowed down
        // without shipping a new client.
        _interval = Duration(seconds: snapshot.pollIntervalSeconds);
      }
      _state.apply(snapshot.versions);
    } on Exception {
      // Offline, backend restarting, relay tunnel flapping — all routine in a
      // shop, and none of them are this layer's problem to report. The caches
      // this feeds simply fall back to their TTLs until it recovers.
      _backoff = _nextBackoff();
    } finally {
      _running = false;
      _scheduleNext();
    }
  }

  Duration _nextBackoff() {
    if (_backoff == Duration.zero) {
      return _interval;
    }
    final doubled = _backoff * 2;
    return doubled > _maxBackoff ? _maxBackoff : doubled;
  }

  void _scheduleNext() {
    if (!_started || _paused) {
      return;
    }
    _timer?.cancel();
    final delay = _backoff > _interval ? _backoff : _interval;
    _timer = Timer(delay, () => unawaited(pollNow()));
  }

  void dispose() {
    stop();
  }
}
