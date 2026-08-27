import 'dart:async';

/// One run of repeated activity, merged as it happens.
class CoalescedBurst<S> {
  CoalescedBurst._({
    required this.value,
    required this.startedAt,
    required DateTime lastAt,
    required this.count,
  }) : _lastAt = lastAt;

  /// Whatever the caller is accumulating — a quantity range, a key tally.
  S value;

  final DateTime startedAt;
  DateTime _lastAt;

  /// How many raw samples this run collapsed.
  int count;

  DateTime get lastAt => _lastAt;

  Duration get duration => _lastAt.difference(startedAt);
}

/// Collapses a burst of repeated events into a single one, emitted when the
/// burst ends.
///
/// Two of the highest-volume telemetry streams are the same shape: a person
/// holding a button, and a barcode scanner typing a code. In the field 93.9% of
/// cart quantity events arrived within 250ms of the previous one on the same
/// line — a held +/- key, one analytics row per repeat — and individual
/// keystrokes were 1,455,832 rows, half of all interaction telemetry. Neither
/// carries any information the run as a whole does not: what matters is that
/// the cashier moved a line from 1 to 7, not the six presses in between.
///
/// A run ends when it goes quiet for [idleTimeout], when the caller settles it
/// explicitly (a scanner's Enter, checkout, teardown), or when it has been open
/// for [maxRunDuration] — so a key held down forever still reports, and a crash
/// loses at most that much.
class BurstCoalescer<S> {
  BurstCoalescer({
    required this.idleTimeout,
    required this.onSettled,
    this.maxRunDuration = const Duration(seconds: 10),
    DateTime Function()? clock,
    Timer Function(Duration, void Function())? scheduler,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _scheduler = scheduler ?? Timer.new;

  final Duration idleTimeout;
  final Duration maxRunDuration;

  /// Called once per run, with everything the run accumulated.
  final void Function(String key, CoalescedBurst<S> burst) onSettled;

  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _scheduler;

  final Map<String, CoalescedBurst<S>> _open = {};
  final Map<String, Timer> _timers = {};

  /// Folds one sample into [key]'s open run, starting a run if none is open.
  ///
  /// [start] builds the accumulator for a fresh run; [merge] folds a sample
  /// into an existing one. Keeping both on the caller is what lets one
  /// coalescer serve a quantity range and a keystroke tally without knowing
  /// anything about either.
  void add(
    String key, {
    required S Function() start,
    required S Function(S current) merge,
  }) {
    final now = _clock();
    final open = _open[key];
    if (open == null) {
      _open[key] = CoalescedBurst<S>._(
        value: start(),
        startedAt: now,
        lastAt: now,
        count: 1,
      );
    } else {
      open.value = merge(open.value);
      open._lastAt = now;
      open.count += 1;
      // A run that never goes idle must still report eventually.
      if (open.duration >= maxRunDuration) {
        settle(key);
        return;
      }
    }
    _restartIdleTimer(key);
  }

  /// Whether a run is currently open for [key].
  bool isOpen(String key) => _open.containsKey(key);

  /// Ends [key]'s run now and emits it. Safe to call when nothing is open.
  void settle(String key) {
    _timers.remove(key)?.cancel();
    final burst = _open.remove(key);
    if (burst == null) {
      return;
    }
    onSettled(key, burst);
  }

  /// Ends every open run. Call before anything that would make a pending run
  /// meaningless or unattributable — checkout, sign-out, teardown.
  void settleAll() {
    for (final key in _open.keys.toList(growable: false)) {
      settle(key);
    }
  }

  /// Drops every open run without emitting. Only for a context where the runs
  /// no longer describe anything real (a cleared cart).
  void discardAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _open.clear();
  }

  void dispose() {
    settleAll();
    discardAll();
  }

  void _restartIdleTimer(String key) {
    _timers.remove(key)?.cancel();
    _timers[key] = _scheduler(idleTimeout, () => settle(key));
  }
}
