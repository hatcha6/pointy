import 'package:flutter/foundation.dart';

/// Where the app is in finding/holding a connection to its backend. Drives the
/// pre-auth connection surface (connecting spinner vs. manual-entry escape
/// hatch) and lets the shell reload once a target is (re)acquired.
enum ConnectionPhase {
  /// Still hunting for the backend during the startup cap.
  connecting,

  /// Talking to the on-prem backend over the LAN.
  connectedLocal,

  /// Talking to the backend through the relay (remote access).
  connectedRelay,

  /// Auto-discovery gave up within the cap; the user may type an address.
  needsManual,
}

/// Observable connection phase, owned by [PointyAppDependencies] and driven by
/// [ConnectionCoordinator].
class ConnectionStatusController extends ChangeNotifier {
  ConnectionPhase _phase = ConnectionPhase.connecting;
  ConnectionPhase get phase => _phase;

  String _shopName = '';
  String get shopName => _shopName;

  bool _searchingInBackground = false;

  /// True while a background re-discovery/sweep is still running even though the
  /// UI may already show the manual-entry surface — lets that surface say
  /// "still trying automatically…".
  bool get searchingInBackground => _searchingInBackground;

  /// Whether the app has a usable target and can show its normal UI.
  bool get isReady =>
      _phase == ConnectionPhase.connectedLocal ||
      _phase == ConnectionPhase.connectedRelay;

  void update(ConnectionPhase phase, {String? shopName}) {
    final nextShop = shopName ?? _shopName;
    if (phase == _phase && nextShop == _shopName) {
      return;
    }
    _phase = phase;
    _shopName = nextShop;
    notifyListeners();
  }

  void setSearching(bool value) {
    if (_searchingInBackground == value) {
      return;
    }
    _searchingInBackground = value;
    notifyListeners();
  }
}
