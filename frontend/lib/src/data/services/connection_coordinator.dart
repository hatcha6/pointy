import 'dart:async';
import 'dart:math' as math;

import '../models/connection_profile.dart';
import '../models/relay_pairing.dart';
import 'api_session.dart';
import 'backend_discovery_service.dart';
import 'connection_profile_storage.dart';
import 'connection_status_controller.dart';
import 'pos_api_service.dart';
import 'relay_endpoints.dart';
import 'relay_ticket_refresh_client.dart';

class ConnectionCoordinator {
  ConnectionCoordinator({
    required PosApiService service,
    required BackendDiscoveryService discovery,
    required ConnectionProfileStorage storage,
    ConnectionStatusController? status,
    RelayTicketRefreshClient? relayTicketRefreshClient,
    List<Duration> startupRecoveryBackoffs = defaultStartupRecoveryBackoffs,
    List<Duration> localReturnBackoffs = defaultLocalReturnBackoffs,
    Duration pairingRetryDelay = defaultPairingRetryDelay,
    Duration resumeCheckAfter = defaultResumeCheckAfter,
  }) : _service = service,
       _discovery = discovery,
       _storage = storage,
       _status = status,
       _relayTicketRefreshClient =
           relayTicketRefreshClient ?? RelayTicketRefreshClient(),
       _returnHunt = [...startupRecoveryBackoffs, ...localReturnBackoffs],
       _pairingRetryDelay = pairingRetryDelay,
       _resumeCheckAfter = resumeCheckAfter;

  final PosApiService _service;
  final BackendDiscoveryService _discovery;
  final ConnectionProfileStorage _storage;
  final ConnectionStatusController? _status;
  final RelayTicketRefreshClient _relayTicketRefreshClient;

  /// The hunt for the LAN whenever the session leaves it: the startup looks,
  /// close together, then the return looks for as long as it takes.
  final List<Duration> _returnHunt;
  final Duration _pairingRetryDelay;
  final Duration _resumeCheckAfter;
  bool _isPairing = false;
  bool _disposed = false;
  DateTime? _lastFailureRecoveryAt;
  Timer? _refreshTimer;

  /// Whether [bootstrap] has run: until then the app chose its target itself
  /// (tests, previews) and the lifecycle hooks leave it alone.
  bool _started = false;

  /// The discovery in flight, which every [rediscover] meanwhile joins.
  Future<bool>? _discoveryInFlight;

  /// The one exchange of the refresh token in flight, which every caller that
  /// needs a ticket meanwhile joins — see [_refreshRelayTicketRemotely].
  Future<_RemoteRefresh>? _remoteRefreshInFlight;

  /// Every write of the stored profile, in order — see [_updateProfile].
  Future<void> _profileWrites = Future<void>.value();

  /// Until when the relay's last word on this shop's subscription — off —
  /// is taken as read, so a burst of refused requests is not a burst of
  /// exchanges. The relay answers that before spending the token, so the
  /// credentials survive it.
  DateTime? _relaySubscriptionInactiveUntil;

  /// Whether the session is on a LAN endpoint this coordinator applied. False
  /// from startup until one is found, and from the moment the session leaves
  /// the LAN — for the relay, or for the manual-address screen.
  bool _onLocal = false;

  /// Counts every settling of where the session lives: onto a LAN endpoint,
  /// or off the LAN. A decision taken before an await — "move to the relay" —
  /// holds only if this has not moved on by the time it lands; see
  /// [_refreshRelayTicketRemotely].
  int _route = 0;

  /// When the app went out of sight, for [noteAppResumed].
  DateTime? _hiddenSince;

  /// The hunt for the LAN while [_onLocal] is false: see [_startHunt].
  Timer? _huntTimer;
  List<Duration> _huntSchedule = const [];
  int _huntAttempt = 0;

  static const _refreshSkew = Duration(minutes: 5);

  /// The least time between two ticket refreshes. A ticket that arrives
  /// already inside its refresh window — a phone clock ahead of the relay's —
  /// would otherwise be refreshed again the moment it was saved, without end.
  static const _minRefreshDelay = Duration(minutes: 1);

  /// How long to wait before asking for a ticket again after the backend
  /// answered pairing without one, or the relay could not be reached for a
  /// refresh. Matches the backend's own relay-unavailable cooldown, so the
  /// retry lands once the shop's uplink has had time to recover instead of
  /// hammering a pairing endpoint that is answering from memory.
  static const defaultPairingRetryDelay = Duration(minutes: 5);

  /// How long a 402 from the relay is remembered before the next refused
  /// request asks again.
  static const _subscriptionInactiveMemory = Duration(minutes: 5);

  /// How long to ignore repeated "local target unreachable" signals after
  /// kicking a recovery, so a burst of failing requests triggers one sweep, not
  /// dozens.
  static const _failureRecoveryDebounce = Duration(seconds: 8);

  /// The first looks after the session leaves the LAN. Close together,
  /// because the usual reasons pass in seconds: a till that booted before the
  /// server's containers did, a server reloading, a phone whose Wi-Fi is
  /// still reconnecting.
  static const defaultStartupRecoveryBackoffs = <Duration>[
    Duration.zero,
    Duration(seconds: 3),
    Duration(seconds: 6),
  ];

  /// How often to look for the LAN after that, for as long as the session is
  /// off it; the last value repeats. This used to stop after the startup
  /// looks, and a desktop till seldom sees the app-resume signal that was
  /// meant to cover the rest — so a till that booted before the server, or
  /// fell back once, stayed on the internet path all day.
  static const defaultLocalReturnBackoffs = <Duration>[
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
    Duration(seconds: 300),
  ];

  /// How long the app must have been out of sight before coming back makes
  /// it check that the LAN is still there — long enough to be carried
  /// somewhere else, not a glance at another window.
  static const defaultResumeCheckAfter = Duration(seconds: 15);

  /// Every Nth look also sweeps the /24, for a server that changed address.
  /// The rest are the cheap race of the stored address, loopback and UDP.
  static const _sweepEveryNthLook = 4;

  Future<void> bootstrap() async {
    _started = true;
    _status?.update(ConnectionPhase.connecting);
    final route = _route;

    // Fast path: race the stored IP, the loopback defaults and UDP broadcast.
    // The stored IP is only a hint here — a stale one loses instead of gating.
    if (await rediscover(includeSweep: false)) {
      return;
    }
    // Settled elsewhere meanwhile — a rediscovery from the app coming back
    // to the foreground found the LAN — or torn down.
    if (_disposed || _route != route) {
      return;
    }

    // Fast path missed. Use the relay if this device has a way in, otherwise
    // let the user type an address — and either way keep hunting for the LAN
    // backend, quickly at first and then for as long as it takes.
    final profile = await _storage.loadProfile();
    final relayProfile = profile == null ? null : await _moveToRelay(profile);
    if (_disposed || _route != route) {
      return;
    }
    if (relayProfile != null) {
      _leaveLocal(
        ConnectionPhase.connectedRelay,
        shopName: relayProfile.shopName,
      );
      return;
    }
    // Fresh install, or no relay credentials: the manual-address screen, with
    // the hunt still running behind it.
    _leaveLocal(ConnectionPhase.needsManual, shopName: profile?.shopName);
  }

  /// Re-runs discovery. On success it swaps the app onto the freshly found
  /// LAN target. Safe to call from anywhere: a call while a discovery is in
  /// flight joins it and shares its answer (it does not start a second, and
  /// [includeSweep] is the first caller's). Returns whether a LAN backend was
  /// (re)acquired.
  Future<bool> rediscover({bool includeSweep = true}) {
    if (_disposed) {
      return Future.value(false);
    }
    return _discoveryInFlight ??= _discoverAndApply(
      includeSweep: includeSweep,
    ).whenComplete(() => _discoveryInFlight = null);
  }

  Future<bool> _discoverAndApply({required bool includeSweep}) async {
    _status?.setSearching(true);
    try {
      final profile = await _storage.loadProfile();
      if (_disposed) {
        return false;
      }
      final endpoint = await _discovery.discover(
        preferredApiBaseUrls: _preferredUrls(profile),
        expectedInstallationId: _expectedInstallation(profile),
        includeSweep: includeSweep,
      );
      if (_disposed || endpoint == null) {
        return false;
      }
      await _applyLocalEndpoint(endpoint);
      return !_disposed;
    } on Object {
      // Discovery itself never throws; the profile store can. Either way this
      // was a look that found nothing, and the hunt looks again.
      return false;
    } finally {
      if (!_disposed) {
        _status?.setSearching(false);
      }
    }
  }

  /// User-supplied escape hatch: connect to an explicitly typed IP or URL. No
  /// identity check — the operator is deliberately overriding, possibly to a
  /// new server. Returns whether the address answered as a Pointy backend.
  Future<bool> connectManually(String urlOrIp) async {
    final normalized = normalizeApiBaseUrl(urlOrIp);
    if (normalized.isEmpty) {
      return false;
    }
    _status?.setSearching(true);
    try {
      final endpoint = await _discovery.probe(normalized);
      if (endpoint == null || _disposed) {
        return false;
      }
      await _applyLocalEndpoint(endpoint);
      return true;
    } finally {
      if (!_disposed) {
        _status?.setSearching(false);
      }
    }
  }

  /// Hook for [PosApiService.onLocalTargetUnreachable]: a request to the LAN
  /// failed at the transport level, whether or not the relay then answered it.
  ///
  /// When the relay answered it, the session has moved itself onto the relay.
  /// The phase says so at once, and the hunt for the way back starts with a
  /// look straight away: most such failures pass in a moment — a dropped
  /// connection, a server reloading — and a till left to the first return
  /// look ran its requests over the internet for a quarter of a minute or
  /// more for nothing.
  ///
  /// When it did not (a timeout, a write that may not be repeated, no relay),
  /// the session is still pointed at the LAN, and one recovery runs —
  /// debounced, so a burst of failing requests is one look, not dozens. It
  /// either re-finds the LAN or, if the address has stopped answering and
  /// this device has relay credentials, moves the session to the relay (a
  /// phone that walked out of the shop's Wi-Fi).
  void notifyLocalTargetUnreachable() {
    if (_disposed || !_onLocal) {
      // Off the LAN already — on the relay, on the manual-address screen, or
      // still starting — with the hunt (or the bootstrap) deciding.
      return;
    }
    if (_service.usesRelay) {
      _leaveLocal(ConnectionPhase.connectedRelay);
      return;
    }
    final now = DateTime.now();
    final last = _lastFailureRecoveryAt;
    if (last != null && now.difference(last) < _failureRecoveryDebounce) {
      return;
    }
    _lastFailureRecoveryAt = now;
    unawaited(_recoverFromLocalFailure());
  }

  /// The app went out of sight (hidden or paused). See [noteAppResumed].
  void noteAppHidden() {
    _hiddenSince ??= DateTime.now();
  }

  /// The app is in front again — the cheapest reliable signal that the
  /// network may have changed (Wi-Fi reconnected, roamed APs, DHCP renewed,
  /// or the device carried somewhere else entirely).
  ///
  /// Off the LAN, it looks for it. On the LAN, after a real absence, it checks
  /// the LAN is still there: a phone put away in the shop and taken out at
  /// home comes back still pointed at the shop's server, and without this
  /// check the first thing to notice was a screen's own request waiting out
  /// its connection. Found at once when it is there; when it is not, the
  /// session moves to the relay before the screens ask.
  Future<void> noteAppResumed() async {
    final hiddenSince = _hiddenSince;
    _hiddenSince = null;
    if (!_started || _disposed) {
      return;
    }
    if (!_onLocal) {
      await rediscover();
      return;
    }
    if (_service.usesRelay) {
      // A rescued request moved the session while nobody was told yet.
      _leaveLocal(ConnectionPhase.connectedRelay);
      return;
    }
    if (hiddenSince == null ||
        DateTime.now().difference(hiddenSince) < _resumeCheckAfter) {
      return;
    }
    _lastFailureRecoveryAt = DateTime.now();
    await _recoverFromLocalFailure();
  }

  /// The session is pointed at the LAN and something says the LAN may be
  /// gone. Looks once, quickly; moves to the relay if it did not answer.
  Future<void> _recoverFromLocalFailure() async {
    final route = _route;
    // The quick race only. A server still at its address answers it at once,
    // and a device that is plainly elsewhere should not first sweep a network
    // that is not the shop's — the hunt sweeps once the session has somewhere
    // to work from.
    if (await rediscover(includeSweep: false)) {
      return;
    }
    // Settled elsewhere meanwhile: a rescued request moved the session onto
    // the relay, or something found the LAN.
    if (_disposed || _route != route || _service.usesRelay) {
      return;
    }
    // Still pointed at a LAN address that does not answer. A timeout never
    // moves the session by itself — a slow LAN backend is the same backend the
    // relay would reach — so the move happens here, once the LAN has also
    // failed to answer discovery.
    final profile = await _storage.loadProfile();
    if (_disposed || profile == null || _route != route) {
      return;
    }
    final relayProfile = await _moveToRelay(profile);
    if (_disposed || _route != route) {
      return;
    }
    if (relayProfile != null) {
      _leaveLocal(
        ConnectionPhase.connectedRelay,
        shopName: relayProfile.shopName,
      );
      return;
    }
    // No way onto the relay: this is the LAN or nothing. The server may have
    // taken a new address on a network that drops broadcast, which only the
    // sweep finds.
    await rediscover();
  }

  /// Points the session at the relay if this device has a way in: a ticket
  /// that is still valid, or a refresh token to mint one. Returns the profile
  /// the session is now using, or null when the relay is not an option — or
  /// when the session was settled elsewhere while the ticket was minted.
  Future<ConnectionProfile?> _moveToRelay(ConnectionProfile profile) async {
    if (profile.hasUsableRelayTarget) {
      _configureRelay(profile);
      _scheduleRefresh(profile);
      return profile;
    }
    // When the stored profile never learned a relay URL (e.g. it paired before
    // the backend reported one), default to the production relay endpoint. The
    // refresh still requires a stored relay refresh token, so unpaired devices
    // are no-ops.
    final relayProfile = profile.relayApiBaseUrl.trim().isEmpty
        ? profile.copyWith(relayApiBaseUrl: kDefaultRelayApiBaseUrl)
        : profile;
    final activated = await _refreshRelayTicketRemotely(
      relayProfile,
      activateRelay: true,
    );
    final refreshed = activated.profile;
    return refreshed != null && _service.usesRelay ? refreshed : null;
  }

  /// The session is off the LAN — on the relay, or on the manual-address
  /// screen. Say so, and hunt for the LAN until it answers.
  void _leaveLocal(ConnectionPhase phase, {String? shopName}) {
    _onLocal = false;
    _route++;
    _status?.update(phase, shopName: shopName);
    _startHunt(_returnHunt);
  }

  /// Looks for the LAN backend on [schedule] (its last delay repeats) until
  /// one answers, the coordinator is disposed, or something else puts the
  /// session back on the LAN. Every [_sweepEveryNthLook]th look sweeps the /24.
  void _startHunt(List<Duration> schedule) {
    _stopHunt();
    if (_disposed || schedule.isEmpty) {
      return;
    }
    _huntSchedule = schedule;
    _scheduleNextLook();
  }

  void _scheduleNextLook() {
    final delay =
        _huntSchedule[math.min(_huntAttempt, _huntSchedule.length - 1)];
    _huntTimer = Timer(delay, () => unawaited(_look()));
  }

  Future<void> _look() async {
    _huntTimer = null;
    if (_disposed || _onLocal) {
      return;
    }
    final attempt = _huntAttempt++;
    final found = await rediscover(
      includeSweep: attempt % _sweepEveryNthLook == 0,
    );
    // Found, finished, or restarted while this look was in flight.
    if (found || _disposed || _onLocal || _huntTimer != null) {
      return;
    }
    _scheduleNextLook();
  }

  void _stopHunt() {
    _huntTimer?.cancel();
    _huntTimer = null;
    _huntAttempt = 0;
  }

  List<String> _preferredUrls(ConnectionProfile? profile) => [
    if (profile?.localApiBaseUrl.trim().isNotEmpty ?? false)
      profile!.localApiBaseUrl,
  ];

  String? _expectedInstallation(ConnectionProfile? profile) {
    final id = profile?.installationId.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  Future<void> _applyLocalEndpoint(PointyBackendEndpoint endpoint) async {
    var otherInstallation = false;
    final localProfile = (await _updateProfile((stored) {
      // A different installation answering where the session already points
      // — a server rebuilt on the same IP and reached through
      // [connectManually]. Relay credentials name the installation they were
      // issued for, and the old one's lead nowhere from this server.
      final knownInstallation = stored?.installationId.trim() ?? '';
      final answeringInstallation = endpoint.installationId.trim();
      otherInstallation =
          knownInstallation.isNotEmpty &&
          answeringInstallation.isNotEmpty &&
          knownInstallation != answeringInstallation;
      var base = stored ?? ConnectionProfile.empty();
      if (otherInstallation) {
        base = base.withoutRelayCredentials();
      }
      // Keep the stored identity/name if a (possibly older) backend omits
      // them, so the installation id stays stable for the next boot's
      // identity check.
      var next = base.copyWith(
        localApiBaseUrl: endpoint.apiBaseUrl,
        installationId: answeringInstallation.isNotEmpty
            ? endpoint.installationId
            : null,
        shopName: endpoint.shopName.trim().isNotEmpty
            ? endpoint.shopName
            : null,
      );
      if (!next.hasUsableRelayTarget) {
        next = next.withoutRelayTicket();
      }
      return next;
    }))!;
    if (_disposed) {
      return;
    }
    if (otherInstallation) {
      // The session keeps its caches when re-pointed at the same address, so
      // say outright that this is not the backend they came from.
      _service.forgetBackendState();
      _relaySubscriptionInactiveUntil = null;
    }
    _onLocal = true;
    _route++;
    _stopHunt();
    _configureLocal(localProfile);
    _scheduleRefresh(localProfile);
    _status?.update(
      ConnectionPhase.connectedLocal,
      shopName: localProfile.shopName,
    );
  }

  Future<void> pairAuthenticatedDevice() async {
    await refreshRelayTicketIfNeeded(force: true);
  }

  /// Hook for [PosApiService.onRelayTicketRejected]: the relay refused the
  /// ticket the session carries. Mints a new one from the device's refresh
  /// token and installs it, answering whether the request may be sent again
  /// — or that the relay refused the device itself, for a subscription that
  /// is off, which no ticket would get past.
  ///
  /// Every request in flight meets the same 401 at once — the sign-in fan-out
  /// alone is a dozen — so the exchange is single-flight: they all wait on
  /// the one refresh, and the refresh token is spent exactly once.
  Future<RelayTicketRecovery> refreshRelayTicketAfterRejection() async {
    if (_disposed || !_service.usesRelay) {
      return RelayTicketRecovery.failed;
    }
    final inactiveUntil = _relaySubscriptionInactiveUntil;
    if (inactiveUntil != null &&
        DateTime.now().toUtc().isBefore(inactiveUntil)) {
      return RelayTicketRecovery.subscriptionInactive;
    }
    final profile = await _storage.loadProfile();
    if (profile == null) {
      return RelayTicketRecovery.failed;
    }
    final exchange = await _refreshRelayTicketRemotely(
      profile,
      activateRelay: true,
    );
    if (exchange.profile != null && _service.usesRelay) {
      return RelayTicketRecovery.refreshed;
    }
    if (exchange.refusedWith == 402) {
      return RelayTicketRecovery.subscriptionInactive;
    }
    return RelayTicketRecovery.failed;
  }

  Future<void> refreshRelayTicketIfNeeded({bool force = false}) async {
    if (_isPairing || _disposed) {
      return;
    }
    final currentProfile = await _storage.loadProfile();
    final now = DateTime.now().toUtc();
    if (!force &&
        currentProfile != null &&
        !currentProfile.shouldRefreshRelayTicketAt(now, _refreshSkew)) {
      _scheduleRefresh(currentProfile);
      return;
    }
    _isPairing = true;
    try {
      if (_service.usesRelay) {
        // Off the LAN, the refresh token is the only way to a ticket.
        if (currentProfile == null) {
          return;
        }
        final exchange = await _refreshRelayTicketRemotely(
          currentProfile,
          activateRelay: true,
        );
        if (exchange.profile == null) {
          await _scheduleRetry();
        }
        return;
      }
      var profile = currentProfile;
      var relayTemporarilyUnavailable = false;
      try {
        final deviceId = await _storage.loadOrCreateDeviceId();
        // The LAN address this pairing goes to. Read now: by the time the
        // answer is back, a rescued request may have moved the session onto
        // the relay, and the relay's address is no LAN address to save.
        final pairedVia = _service.baseUrl;
        final pairing = await _service.requestRelayPairing(deviceId: deviceId);
        final savedProfile = (await _updateProfile((stored) {
          final storedLocal = stored?.localApiBaseUrl.trim() ?? '';
          return _profileFromPairing(
            pairing,
            localApiBaseUrl: storedLocal.isNotEmpty
                ? stored!.localApiBaseUrl
                : pairedVia,
            existingProfile: stored,
          );
        }))!;
        if (_disposed) {
          return;
        }
        _installCredentials(savedProfile);
        if (pairing.hasTicket) {
          return;
        }
        // The backend answered without a ticket: its link to the relay is
        // down, or it is answering from memory during its cooldown. The
        // credentials this device already holds were kept (see
        // _profileFromPairing); if they are due, the relay is asked directly
        // below — it answers refreshes on its own, without the shop's uplink.
        profile = savedProfile;
        relayTemporarilyUnavailable = pairing.reason == 'relay_unavailable';
      } on Object {
        // Discovery and pairing are opportunistic. Normal LAN-only operation
        // should continue when the relay is unavailable or unsubscribed.
      }
      if (profile == null) {
        return;
      }
      if (!profile.shouldRefreshRelayTicketAt(now, _refreshSkew)) {
        _scheduleRefresh(profile);
        return;
      }
      final exchange = await _refreshRelayTicketRemotely(
        profile,
        activateRelay: _service.usesRelay,
      );
      if (exchange.profile == null) {
        await _scheduleRetry(transient: relayTemporarilyUnavailable);
      }
    } finally {
      _isPairing = false;
    }
  }

  /// Puts [profile]'s ticket to use where the session is now: as the ticket it
  /// carries on the relay — or is moving onto, when [activateRelay] — or else
  /// as the way out of the LAN address the session keeps using.
  void _installCredentials(
    ConnectionProfile profile, {
    bool activateRelay = false,
  }) {
    if (activateRelay || _service.usesRelay) {
      // A pairing that issued nothing leaves the session's own ticket alone.
      // Whether a ticket is still good is the relay's call, not this
      // device's clock: a phone running ahead must not be kept off the relay
      // by a ticket minted a moment ago.
      if (profile.relayToken.trim().isNotEmpty &&
          profile.relayApiBaseUrl.trim().isNotEmpty) {
        _configureRelay(profile);
      }
    } else {
      _configureLocal(profile, baseUrl: _service.baseUrl);
    }
    _scheduleRefresh(profile);
  }

  /// Points the session at the LAN — at [baseUrl], or else at [profile]'s LAN
  /// address — with [profile]'s ticket, while it is good, as the way out.
  void _configureLocal(ConnectionProfile profile, {String? baseUrl}) {
    _service.configureConnectionTarget(
      baseUrl: baseUrl ?? profile.localApiBaseUrl,
      fallbackTarget: profile.hasUsableRelayTarget
          ? ApiConnectionTarget(
              baseUrl: profile.relayApiBaseUrl,
              relayToken: profile.relayToken,
              relayTokenExpiresAt: profile.relayTokenExpiresAt,
            )
          : null,
    );
  }

  void _configureRelay(ConnectionProfile profile) {
    _service.configureConnectionTarget(
      baseUrl: profile.relayApiBaseUrl,
      relayToken: profile.relayToken,
    );
  }

  /// Trades the device's refresh token for a new ticket at the relay and
  /// installs it — on the relay as the primary target, or as the LAN's
  /// fallback. The profile is null when the device has no way in, the relay
  /// could not be reached, or it refused; [_RemoteRefresh.refusedWith] then
  /// carries the relay's status, when it answered at all.
  ///
  /// Single-flight: a refresh token is consumed the moment the relay reads
  /// it, so two exchanges of the same token cannot both succeed. The second
  /// used to come back 401 and, worse, wipe the credentials the first had
  /// just saved. Now a caller that arrives mid-exchange waits for it and
  /// installs its result.
  ///
  /// [activateRelay] is a decision taken before the exchange, and it only
  /// stands if the session was not settled elsewhere while the relay was
  /// asked. The hunt finding the LAN meanwhile used to be undone the moment
  /// the ticket arrived: the session went back onto the relay while the phase
  /// still said LAN and the hunt had stopped, so nothing ever brought it back
  /// and the till ran over the internet until it was restarted.
  Future<_RemoteRefresh> _refreshRelayTicketRemotely(
    ConnectionProfile profile, {
    required bool activateRelay,
  }) async {
    final route = _route;
    var exchange = _remoteRefreshInFlight;
    if (exchange == null) {
      exchange = _consumeRelayRefreshToken(profile);
      _remoteRefreshInFlight = exchange;
      unawaited(
        exchange.whenComplete(() {
          if (identical(_remoteRefreshInFlight, exchange)) {
            _remoteRefreshInFlight = null;
          }
        }),
      );
    }
    final result = await exchange;
    final refreshed = result.profile;
    if (refreshed == null || _disposed) {
      return result;
    }
    _installCredentials(
      refreshed,
      activateRelay: activateRelay && route == _route,
    );
    return result;
  }

  Future<_RemoteRefresh> _consumeRelayRefreshToken(
    ConnectionProfile profile,
  ) async {
    final now = DateTime.now().toUtc();
    var current = profile;
    if (!current.hasUsableRelayRefreshAt(now)) {
      // The caller's copy may be older than what is stored — another
      // exchange may just have saved a fresh pair. Only a stored profile
      // with no way in is cleared.
      current = await _storage.loadProfile() ?? current;
      if (!current.hasUsableRelayRefreshAt(now)) {
        final noWayIn = current;
        await _updateProfile((stored) {
          final latest = stored ?? noWayIn;
          return latest.hasUsableRelayRefreshAt(now)
              ? null
              : latest.withoutRelayCredentials();
        });
        return const _RemoteRefresh();
      }
    }

    try {
      final deviceId = await _storage.loadOrCreateDeviceId();
      final pairing = await _relayTicketRefreshClient.refreshTicket(
        relayApiBaseUrl: current.relayApiBaseUrl,
        refreshToken: current.relayRefreshToken,
        request: RelayPairingRequest(deviceId: deviceId),
      );
      if (!pairing.hasTicket) {
        return const _RemoteRefresh();
      }
      final exchanged = current;
      var otherInstallation = false;
      final refreshed = await _updateProfile((stored) {
        // Saved onto what is stored now, not onto the copy this exchange
        // started from: a discovery may have saved a new LAN address while
        // the relay was asked, and writing the old one back over it sent the
        // next boot looking in the wrong place.
        final base = stored ?? exchanged;
        final storedInstallation = base.installationId.trim();
        final ticketInstallation = pairing.installationId.trim();
        otherInstallation =
            storedInstallation.isNotEmpty &&
            ticketInstallation.isNotEmpty &&
            storedInstallation != ticketInstallation;
        if (otherInstallation) {
          // The device moved to another shop's server while this was on the
          // wire; the old shop's ticket is no way into this one.
          return null;
        }
        return _profileFromPairing(
          pairing,
          localApiBaseUrl: base.localApiBaseUrl,
          existingProfile: base,
        );
      });
      if (otherInstallation || refreshed == null) {
        return const _RemoteRefresh();
      }
      _relaySubscriptionInactiveUntil = null;
      return _RemoteRefresh(profile: refreshed);
    } on RelayTicketRefreshException catch (exception) {
      if (exception.isCredentialRejected) {
        await _dropRejectedRelayCredentials(current.relayRefreshToken);
      } else if (exception.isSubscriptionInactive) {
        // Not a word against the credentials: the relay answers this
        // before spending the token, and the device keeps them for when
        // the subscription is back. Remember the answer for a while, so
        // every refused request meanwhile is not another exchange.
        _relaySubscriptionInactiveUntil = DateTime.now().toUtc().add(
          _subscriptionInactiveMemory,
        );
      }
      return _RemoteRefresh(refusedWith: exception.statusCode);
    } on Object {
      // Unreachable or slow relay: the credentials are still good, and the
      // next attempt may well get through.
      return const _RemoteRefresh();
    }
  }

  /// Forget the relay credentials the relay just refused — unless the stored
  /// ones are already different: a refresh that lost a race has nothing to
  /// say about the pair the winner saved.
  Future<void> _dropRejectedRelayCredentials(String rejectedRefreshToken) {
    return _updateProfile((stored) {
      if (stored == null) {
        return null;
      }
      final storedRefreshToken = stored.relayRefreshToken.trim();
      if (storedRefreshToken.isNotEmpty &&
          storedRefreshToken != rejectedRefreshToken.trim()) {
        return null;
      }
      return stored.withoutRelayCredentials();
    });
  }

  /// Writes the stored profile as [change] makes it from what is stored at
  /// that moment, one write at a time; [change] returning null leaves it as
  /// it is. Resolves to the profile stored afterwards.
  ///
  /// The profile has two writers that run side by side: discovery (the LAN
  /// address, the shop's identity) and the relay exchanges (the credentials).
  /// Each used to save its own copy, read before a network round trip, over
  /// whatever the other had saved meanwhile. A discovery landing during an
  /// exchange put the old credentials back — with the refresh token the relay
  /// had just spent — and the device's next refresh was refused, losing its
  /// way in from outside the shop.
  Future<ConnectionProfile?> _updateProfile(
    ConnectionProfile? Function(ConnectionProfile? stored) change,
  ) {
    final update = _profileWrites.then((_) async {
      final stored = await _storage.loadProfile();
      final next = change(stored);
      if (next == null) {
        return stored;
      }
      await _storage.saveProfile(next);
      return next;
    });
    _profileWrites = update.then<void>((_) {}, onError: (Object _) {});
    return update;
  }

  void _scheduleRefresh(ConnectionProfile profile) {
    _refreshTimer?.cancel();
    final expiresAt = profile.relayTokenExpiresAt;
    if (expiresAt == null || profile.relayToken.trim().isEmpty) {
      return;
    }
    final refreshAt = expiresAt.toUtc().subtract(_refreshSkew);
    var delay = refreshAt.difference(DateTime.now().toUtc());
    if (delay < _minRefreshDelay) {
      delay = _minRefreshDelay;
    }
    _refreshTimer = Timer(delay, () => unawaited(refreshRelayTicketIfNeeded()));
  }

  /// Ask for a ticket again in a while. Worth doing when the device still
  /// holds a refresh token to keep alive, or when the backend said the relay
  /// was only temporarily out of reach ([transient]); a device with neither
  /// has nothing to retry for until someone signs in again. Judged on what is
  /// stored now, not on a caller's copy: the attempt that just failed may
  /// have dropped the credentials it was made with.
  Future<void> _scheduleRetry({bool transient = false}) async {
    _refreshTimer?.cancel();
    if (_disposed) {
      return;
    }
    if (!transient) {
      final stored = await _storage.loadProfile();
      if (stored == null ||
          !stored.hasUsableRelayRefreshAt(DateTime.now().toUtc())) {
        return;
      }
    }
    _refreshTimer = Timer(
      _pairingRetryDelay,
      () => unawaited(refreshRelayTicketIfNeeded()),
    );
  }

  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _stopHunt();
  }
}

/// One exchange of the refresh token: the profile it produced, or the relay's
/// status when it refused ([refusedWith] is null when it never answered).
class _RemoteRefresh {
  const _RemoteRefresh({this.profile, this.refusedWith});

  final ConnectionProfile? profile;
  final int? refusedWith;
}

ConnectionProfile _profileFromPairing(
  RelayPairing pairing, {
  required String localApiBaseUrl,
  ConnectionProfile? existingProfile,
}) {
  final relayApiBaseUrl = pairing.relayPublicApiUrl.trim().isNotEmpty
      ? _relayApiBaseUrl(pairing.relayPublicApiUrl)
      : (existingProfile?.relayApiBaseUrl.trim().isNotEmpty ?? false)
      ? existingProfile!.relayApiBaseUrl
      : kDefaultRelayApiBaseUrl;
  if (!pairing.hasTicket) {
    // Nothing was issued — but the credentials this device already holds are
    // its only way in from outside the shop, so they stay. A ticket-less
    // answer is far more often the backend's own link to the relay (down, or
    // remembered as down for its cooldown) than a lost entitlement, and the
    // relay is the judge of the latter: it refuses a lapsed subscription when
    // the credentials are next used, and they are dropped then. Until this
    // held, one bad uplink minute at sign-in stranded a phone for the day.
    return ConnectionProfile(
      localApiBaseUrl: localApiBaseUrl,
      relayApiBaseUrl: relayApiBaseUrl,
      relayToken: existingProfile?.relayToken ?? '',
      relayRefreshToken: existingProfile?.relayRefreshToken ?? '',
      installationId: pairing.installationId.isNotEmpty
          ? pairing.installationId
          : (existingProfile?.installationId ?? ''),
      shopName: pairing.shopName.isNotEmpty
          ? pairing.shopName
          : (existingProfile?.shopName ?? ''),
      relayTokenExpiresAt: existingProfile?.relayTokenExpiresAt,
      relayRefreshExpiresAt: existingProfile?.relayRefreshExpiresAt,
    );
  }
  // The expiries in this device's own clock. The relay stamps them with its
  // clock; a phone running ten minutes ahead read every fresh 15-minute
  // ticket as already inside its refresh window, refreshed it at once, and
  // again a minute later, for as long as it ran — an exchange a minute per
  // skewed device, against the relay's rate limit. With the relay's own
  // issue time in hand the skew is measured, not guessed.
  final skew = _clockSkewOf(pairing);
  return ConnectionProfile(
    localApiBaseUrl: localApiBaseUrl,
    relayApiBaseUrl: relayApiBaseUrl,
    relayToken: pairing.relayToken,
    relayRefreshToken: pairing.hasRefreshToken ? pairing.relayRefreshToken : '',
    installationId: pairing.installationId.isNotEmpty
        ? pairing.installationId
        : (existingProfile?.installationId ?? ''),
    shopName: pairing.shopName.isNotEmpty
        ? pairing.shopName
        : (existingProfile?.shopName ?? ''),
    relayTokenExpiresAt: _inDeviceClock(pairing.expiresAt, skew),
    relayRefreshExpiresAt: _inDeviceClock(pairing.refreshExpiresAt, skew),
  );
}

/// How far the relay's clock is from this device's: the ticket's issue time
/// (the relay's now, give or take the round trip) against the device's now.
/// Zero when the answer carries no issue time — an older relay or backend —
/// so the expiries are taken as they are, as before.
Duration _clockSkewOf(RelayPairing pairing) {
  final issuedAt = pairing.issuedAt;
  if (issuedAt == null) {
    return Duration.zero;
  }
  return issuedAt.toUtc().difference(DateTime.now().toUtc());
}

DateTime? _inDeviceClock(DateTime? relayTime, Duration skew) {
  return relayTime?.toUtc().subtract(skew);
}

String _relayApiBaseUrl(String relayPublicApiUrl) {
  final trimmed = relayPublicApiUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) {
    return '';
  }
  if (trimmed.endsWith('/api')) {
    return trimmed;
  }
  return '$trimmed/api';
}
