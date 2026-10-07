import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/services/client_update_service.dart';
import '../../../data/services/device_settings_storage_service.dart';

/// An app build this machine should be offered, and the one it is running.
@immutable
class AppUpdateOffer {
  const AppUpdateOffer({required this.currentVersion, required this.release});

  final String currentVersion;
  final ClientRelease release;
}

/// Decides when this machine is offered the app build its backend now serves.
///
/// A remote update replaces the backend and publishes the matching client
/// installers on the LAN, but nothing told the tills: they ran the old app
/// until somebody opened device settings. This asks the manifest at the two
/// moments an update can have appeared — when someone signs in, and when the
/// backend's responses start naming a different release — and holds an
/// [offer] for the screen to show.
///
/// The backend comes back up *before* the update publishes the new installers
/// (`install.sh` starts the stack, then copies `clients/`), so the first look
/// after a release change can still find the old manifest. While the backend
/// names a release newer than this app, an empty answer is retried a few times
/// over the next quarter of an hour instead of being believed.
class AppUpdatePrompter extends ChangeNotifier {
  AppUpdatePrompter({
    required Future<ClientUpdateStatus> Function() check,
    required ValueListenable<String?> serverVersion,
    Future<String?> Function()? loadPostponed,
    Future<void> Function(String version)? savePostponed,
    List<Duration> retryDelays = defaultRetryDelays,
  }) : _check = check,
       _serverVersion = serverVersion,
       _loadPostponed =
           loadPostponed ??
           const DeviceSettingsStorageService().loadPostponedAppUpdate,
       _savePostponed =
           savePostponed ??
           const DeviceSettingsStorageService().savePostponedAppUpdate,
       _retryDelays = retryDelays;

  static const List<Duration> defaultRetryDelays = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  final Future<ClientUpdateStatus> Function() _check;
  final ValueListenable<String?> _serverVersion;
  final Future<String?> Function() _loadPostponed;
  final Future<void> Function(String version) _savePostponed;
  final List<Duration> _retryDelays;

  AppUpdateOffer? _offer;
  bool _checking = false;
  bool _listening = false;
  bool _disposed = false;
  int _retriesUsed = 0;
  Timer? _retryTimer;

  /// The build already put in front of the user this run. Not offered twice:
  /// someone who backed out of the system installer can still reach it from
  /// device settings, and the next start asks again.
  String? _shownVersion;

  /// The update waiting to be shown, or null.
  AppUpdateOffer? get offer => _offer;

  /// Called at each sign-in: asks once now, and from then on whenever the
  /// backend's responses name a different release.
  void start() {
    if (_disposed) {
      return;
    }
    if (!_listening) {
      _listening = true;
      _serverVersion.addListener(_handleServerVersionChanged);
    }
    unawaited(checkNow());
  }

  /// Ask the manifest now. Overlapping calls collapse into the one in flight.
  Future<void> checkNow() async {
    if (_checking || _disposed) {
      return;
    }
    _checking = true;
    try {
      final status = await _check();
      if (_disposed) {
        return;
      }
      await _apply(status);
    } on Object {
      // A failed look is no news; the next trigger asks again.
    } finally {
      _checking = false;
    }
  }

  /// Hands the waiting offer to the screen that is about to show it.
  AppUpdateOffer? takeOffer() {
    final offer = _offer;
    if (offer == null) {
      return null;
    }
    _offer = null;
    _shownVersion = offer.release.version;
    return offer;
  }

  /// "Later": this build is not offered again on this machine. The next build
  /// is. A storage failure only means it may be offered once more.
  Future<void> postpone(String version) async {
    try {
      await _savePostponed(version);
    } on Object {
      return;
    }
  }

  Future<void> _apply(ClientUpdateStatus status) async {
    final release = status.available;
    if (release == null) {
      _scheduleRetry(status);
      return;
    }
    _cancelRetry();
    if (release.version == _shownVersion ||
        release.version == _offer?.release.version) {
      return;
    }
    final String? postponed;
    try {
      postponed = await _loadPostponed();
    } on Object {
      return;
    }
    if (_disposed || postponed == release.version) {
      return;
    }
    _offer = AppUpdateOffer(
      currentVersion: status.currentVersion,
      release: release,
    );
    notifyListeners();
  }

  void _handleServerVersionChanged() {
    // A different release is fresh news: the retry budget starts over.
    _cancelRetry();
    _retriesUsed = 0;
    unawaited(checkNow());
  }

  void _scheduleRetry(ClientUpdateStatus status) {
    final server = _serverVersion.value;
    final serverIsAhead =
        server != null && isNewerVersion(server, status.currentVersion);
    if (status.unsupported ||
        !serverIsAhead ||
        _retriesUsed >= _retryDelays.length) {
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelays[_retriesUsed], () {
      _retryTimer = null;
      unawaited(checkNow());
    });
    _retriesUsed += 1;
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRetry();
    if (_listening) {
      _serverVersion.removeListener(_handleServerVersionChanged);
    }
    super.dispose();
  }
}
