import 'dart:async';

import 'server_state.dart';

/// Turns "the server says domain X changed" into "this screen refreshes".
///
/// Caching without this is what made an admin's edit invisible until a
/// restart: the caches were keyed correctly, but nothing ever went back and
/// asked again. A holder registers once, names the domains it depends on, and
/// is called when one of them moves.
///
/// Three things it does that a bare listener does not, each of them the
/// difference between "instant" and "worse than stale":
///
/// - **Coalesces.** A stock counter moves on every sale line in the shop. A
///   burst of changes is one refresh, not one per bump.
/// - **Waits for a safe moment.** `canRun` lets a holder refuse — mid-sale,
///   mid-scan, while a payment sheet is open. The refresh is not dropped; it
///   is held and runs the moment [gateOpened] says the coast is clear. A
///   cashier must never have the screen move under their hands.
/// - **Never overlaps itself.** A change arriving during a refresh queues one
///   more run afterwards rather than racing it.
///
/// It carries no data of its own: every registered callback goes back to the
/// normal, permission-checked endpoint. Revalidation therefore cannot widen
/// what a user can see, whichever domain moved and whoever moved it.
class Revalidator {
  Revalidator(this._state) {
    _state.addListener(_onServerStateChanged);
  }

  final ServerStateNotifier _state;
  final List<_Watcher> _watchers = [];
  bool _disposed = false;

  /// Refresh [onStale] whenever any of [domains] moves.
  ///
  /// [debounce] collapses a burst. [canRun] defers — return false while the
  /// holder is busy and call [gateOpened] when it is not.
  RevalidationSubscription watch({
    required Set<String> domains,
    required Future<void> Function() onStale,
    Duration debounce = const Duration(milliseconds: 400),
    bool Function()? canRun,
    String label = '',
  }) {
    final watcher = _Watcher(
      domains: domains,
      onStale: onStale,
      debounce: debounce,
      canRun: canRun,
      label: label,
    );
    _watchers.add(watcher);
    return RevalidationSubscription._(() {
      watcher.dispose();
      _watchers.remove(watcher);
    });
  }

  /// A holder that was refusing refreshes is free again — run whatever was
  /// held back for it. Cheap to call often; watchers with nothing pending
  /// do nothing.
  void gateOpened() {
    for (final watcher in _watchers) {
      watcher.runIfPending();
    }
  }

  void _onServerStateChanged() {
    final changed = _state.lastChanged;
    if (changed.isEmpty) {
      return;
    }
    for (final watcher in _watchers) {
      if (watcher.domains.any(changed.contains)) {
        watcher.markStale();
      }
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _state.removeListener(_onServerStateChanged);
    for (final watcher in List.of(_watchers)) {
      watcher.dispose();
    }
    _watchers.clear();
  }
}

class RevalidationSubscription {
  RevalidationSubscription._(this._cancel);

  final void Function() _cancel;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _cancel();
  }
}

class _Watcher {
  _Watcher({
    required this.domains,
    required this.onStale,
    required this.debounce,
    required this.canRun,
    required this.label,
  });

  final Set<String> domains;
  final Future<void> Function() onStale;
  final Duration debounce;
  final bool Function()? canRun;
  final String label;

  Timer? _debounceTimer;
  bool _pending = false;
  bool _running = false;
  bool _disposed = false;

  void markStale() {
    if (_disposed) {
      return;
    }
    _pending = true;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _attempt);
  }

  void runIfPending() {
    if (_pending && _debounceTimer?.isActive != true) {
      _attempt();
    }
  }

  void _attempt() {
    if (_disposed || !_pending || _running) {
      return;
    }
    // Held, not dropped: the holder is mid-sale or mid-scan. [_pending] stays
    // set, so gateOpened() picks this up the moment it is safe.
    if (canRun != null && !canRun!()) {
      return;
    }
    _pending = false;
    _running = true;
    onStale()
        .catchError((Object _) {
          // A failed refresh leaves the old data on screen, which is exactly the
          // right outcome — the screen keeps working and the next bump (or the
          // cache's own TTL) tries again. Swallowed deliberately: a background
          // revalidation must never surface as an error the cashier has to dismiss.
        })
        .whenComplete(() {
          _running = false;
          if (_disposed) {
            return;
          }
          // A change that landed while we were refreshing: go round once more.
          if (_pending) {
            _attempt();
          }
        });
  }

  void dispose() {
    _disposed = true;
    _pending = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }
}
