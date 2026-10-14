import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/moamalat.dart';
import '../../../data/repositories/moamalat_repository.dart';

/// A till's live view of the card terminal while its payment sheet is open.
///
/// It asks for every swipe no payment has claimed yet — whatever the amount,
/// and from [lookbackBeforeOpen] before the sheet opened, because a cashier
/// often swipes the card before going to the checkout. The sheet then pairs
/// those swipes with its card tenders (`planSwipes`).
///
/// Each poll is also the heartbeat that keeps the backend's fast loop running
/// (`apps.payments.moamalat.watch`). It stops by itself — when the sheet
/// closes ([dispose]), after [maxOpen] however long the sheet stays up, after
/// a few failed polls, and at once when there is no live link — so a till can
/// never keep Moamalat busy. The server enforces its own ceiling regardless.
class MoamalatLiveWatch extends ChangeNotifier {
  MoamalatLiveWatch(
    this._repository, {
    this.interval = const Duration(seconds: 5),
    this.maxOpen = const Duration(minutes: 10),
    this.lookbackBeforeOpen = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MoamalatRepository _repository;
  final Duration interval;
  final Duration maxOpen;
  final Duration lookbackBeforeOpen;
  final DateTime Function() _clock;

  static const _maxFailures = 3;

  MoamalatWatch? latest;
  bool get isPolling => _timer != null;

  /// The link is live and the terminal is being read.
  bool get isLive =>
      latest?.state == MoamalatLinkState.alive && (latest?.watching ?? false);

  /// Every unclaimed swipe in the window, newest first.
  List<MoamalatSwipe> get swipes => latest?.swipes ?? const [];

  Timer? _timer;
  DateTime? _openedAt;
  int _failures = 0;
  bool _inFlight = false;
  bool _disposed = false;
  bool _gaveUp = false;

  /// Start watching (once per sheet). A no-op once it has given up.
  void start() {
    if (_timer != null || _gaveUp || _disposed) return;
    _openedAt ??= _clock();
    _failures = 0;
    _timer = Timer.periodic(interval, (_) => _poll());
    unawaited(_poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _giveUp() {
    _gaveUp = true;
    stop();
  }

  Future<void> _poll() async {
    if (_disposed || _inFlight) return;
    final opened = _openedAt!;
    final open = _clock().difference(opened);
    if (open >= maxOpen) {
      _giveUp();
      return;
    }
    _inFlight = true;
    final result = await _repository.watch(lookback: open + lookbackBeforeOpen);
    _inFlight = false;
    if (_disposed) return;
    switch (result) {
      case Ok(:final value):
        _failures = 0;
        latest = value;
        if (value.state != MoamalatLinkState.alive) {
          _giveUp();
        }
      case Error():
        _failures += 1;
        if (_failures >= _maxFailures) {
          _giveUp();
        }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
