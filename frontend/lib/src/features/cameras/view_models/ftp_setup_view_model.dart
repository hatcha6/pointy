import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/camera.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../ftp_setup_state.dart';

/// One FTP upload setup, as its connection page shows it while an installer
/// stands at the DVR.
///
/// The page is live on purpose: it refreshes every few seconds, so pressing
/// "Test" on the DVR turns "waiting" into "connected" here without anyone
/// touching the till. That moment is the whole installation.
class FtpSetupViewModel extends ChangeNotifier {
  FtpSetupViewModel(
    this._repository, {
    required Recorder recorder,
    this.refreshInterval = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _recorder = recorder,
       _clock = clock ?? DateTime.now;

  final SurveillanceRepository _repository;
  final Duration refreshInterval;
  final DateTime Function() _clock;

  Recorder _recorder;
  String? _resolvedAddress;
  bool _addressResolved = false;
  bool _isRegenerating = false;
  bool _isRefreshing = false;
  Timer? _timer;
  bool _disposed = false;

  Recorder get recorder => _recorder;
  FtpAccountInfo? get account => _recorder.ftp;

  /// The address to type into the DVR: what this device reaches the server
  /// at, or failing that the one last stored for this setup.
  String? get serverAddress {
    final resolved = _resolvedAddress;
    if (resolved != null && resolved.isNotEmpty) {
      return resolved;
    }
    final stored = account?.host ?? '';
    return stored.isEmpty ? null : stored;
  }

  bool get isResolvingAddress => !_addressResolved;
  bool get isRegenerating => _isRegenerating;

  /// Only someone who may change recorders is sent the password, so its
  /// presence is also the answer to "may this person manage the setup".
  bool get canManage => account?.password != null;

  FtpSetupStatus? get status {
    final account = this.account;
    return account == null ? null : ftpSetupStatusOf(account, now: _clock());
  }

  Future<void> start() async {
    await _resolveAddress();
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (_isRefreshing || _disposed) {
      return;
    }
    _isRefreshing = true;
    final result = await _repository.loadRecorder(_recorder.id);
    _isRefreshing = false;
    if (result case Ok<Recorder>()) {
      _apply(result.value);
    }
  }

  Future<bool> regeneratePassword() async {
    if (_isRegenerating) {
      return false;
    }
    _isRegenerating = true;
    _notify();
    final result = await _repository.regenerateFtpPassword(_recorder.id);
    _isRegenerating = false;
    switch (result) {
      case Ok<Recorder>():
        _apply(result.value);
        return true;
      case Error<Recorder>():
        _notify();
        return false;
    }
  }

  Future<void> _resolveAddress() async {
    final address = await _repository.ftpServerAddress();
    if (_disposed) {
      return;
    }
    _resolvedAddress = address;
    _addressResolved = true;
    _notify();
    final account = this.account;
    if (address == null || account == null || !canManage) {
      return;
    }
    if (account.host == address) {
      return;
    }
    // PASV has to announce the address the DVR was given; this device is the
    // one that can see what that is, so it tells the server.
    final result = await _repository.setFtpAddress(_recorder.id, address);
    if (result case Ok<Recorder>()) {
      _apply(result.value);
    }
  }

  void _apply(Recorder recorder) {
    _recorder = recorder;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
