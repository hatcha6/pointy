import 'connection_status_controller.dart';

/// Called for each move of the app's connection: [from] and [to] are `lan`,
/// `relay`, or — for the first route the app settles on — `startup`.
typedef ConnectionRouteChanged =
    void Function({required String from, required String to});

/// Reports every move of the connection between the shop's LAN and the relay,
/// including starting out on the relay.
///
/// A till on the relay still works — slowly, over the shop's internet — so
/// nothing on screen looks wrong, and a field export could not tell a slow
/// backend from a till that spent the day on the internet path. One row per
/// move answers that.
class ConnectionRouteReporter {
  ConnectionRouteReporter(this._status, this._onChanged) {
    _route = _routeOf(_status.phase);
    if (_route == _relay) {
      _onChanged(from: _startup, to: _relay);
    }
    _status.addListener(_handleStatusChanged);
  }

  static const _lan = 'lan';
  static const _relay = 'relay';
  static const _startup = 'startup';

  final ConnectionStatusController _status;
  final ConnectionRouteChanged _onChanged;
  String? _route;

  void _handleStatusChanged() {
    final next = _routeOf(_status.phase);
    if (next == null || next == _route) {
      return;
    }
    final previous = _route ?? _startup;
    _route = next;
    _onChanged(from: previous, to: next);
  }

  void dispose() => _status.removeListener(_handleStatusChanged);

  static String? _routeOf(ConnectionPhase phase) {
    return switch (phase) {
      ConnectionPhase.connectedLocal => _lan,
      ConnectionPhase.connectedRelay => _relay,
      ConnectionPhase.connecting || ConnectionPhase.needsManual => null,
    };
  }
}
