import 'dart:convert';

export 'local_server_host_stub.dart'
    if (dart.library.io) 'local_server_host_io.dart';

/// What starting the server keeper's task came to. See
/// `windows/runner/server_host.cpp`.
enum KeeperStartOutcome {
  /// The task was not running and has been started.
  started,

  /// It already was.
  running,

  /// Not installed, or this Windows user may not see it.
  missing,

  /// Installed, but this Windows user may not start it.
  denied,

  /// Installed and turned off.
  disabled,

  /// Anything else; the next attempt may do better.
  failed;

  static KeeperStartOutcome parse(String? value) => switch (value) {
    'started' => started,
    'running' => running,
    'missing' => missing,
    'denied' => denied,
    'disabled' => disabled,
    _ => failed,
  };

  /// Only an administrator can put these right: the one-time setup.
  bool get needsSetup => this == missing || this == denied;
}

/// What launching the one-time administrator setup came to.
enum KeeperSetupOutcome {
  /// Windows' administrator prompt was accepted; the setup runs.
  launched,

  /// The prompt was refused.
  cancelled,

  /// The keeper script is not on this PC.
  missing,

  failed;

  static KeeperSetupOutcome parse(String? value) => switch (value) {
    'launched' => launched,
    'cancelled' => cancelled,
    'missing' => missing,
    _ => failed,
  };
}

/// The keeper's `keepalive-state.json`, which it rewrites at least once a
/// cycle (about a minute; longer while WSL boots).
class KeeperHeartbeat {
  const KeeperHeartbeat({
    required this.at,
    required this.healthy,
    required this.stage,
  });

  final DateTime at;

  /// The path a till takes answered: this PC's LAN address, the forward, the
  /// edge and the backend behind it.
  final bool healthy;

  /// The keeper window's title state: `STARTING`, `RUNNING`,
  /// `WAITING FOR WSL`, `PROBLEM - see log`, … Empty from a keeper older than
  /// the client start.
  final String stage;

  bool get reportsProblem => stage.startsWith('PROBLEM');
  bool get waitingForWsl => stage.startsWith('WAITING FOR WSL');

  /// Null for anything that is not a whole heartbeat: the keeper may be
  /// halfway through rewriting it.
  static KeeperHeartbeat? parse(String text) {
    // Windows PowerShell 5.1 writes UTF-8 with a byte-order mark.
    final body = text.startsWith('\uFEFF') ? text.substring(1) : text;
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) {
        return null;
      }
      final at = DateTime.tryParse('${json['heartbeat_at'] ?? ''}');
      if (at == null) {
        return null;
      }
      return KeeperHeartbeat(
        at: at,
        healthy: json['healthy'] == true,
        stage: '${json['stage'] ?? ''}',
      );
    } on FormatException {
      return null;
    }
  }
}

/// The Windows side of a till that runs on the shop's WSL server PC. Every
/// method is safe to call anywhere: off Windows, or on a PC that is not the
/// server, [isServerPc] is false and nothing else is called.
abstract class LocalServerHostPlatform {
  /// This PC runs the shop's server in WSL (its keeper installed or not) and
  /// it was not moved to Linux.
  Future<bool> isServerPc();

  /// Where the keeper logs, for support staff.
  String get logPath;

  Future<KeeperHeartbeat?> readHeartbeat();

  Future<KeeperStartOutcome> startKeeper();

  /// Starts the keeper at this user's next sign-ins (the `PointyServer` Run
  /// entry).
  Future<bool> registerSignInStart();

  /// Re-installs the keeper elevated: one administrator prompt.
  Future<KeeperSetupOutcome> runSetup();

  /// Runs the keeper's `-Restart` elevated, in a minimised window of this
  /// session: one administrator prompt.
  Future<KeeperSetupOutcome> runKeeperElevated();
}

/// Every PC that is not the shop's WSL server: web, macOS, Linux, Android, and
/// tests that do not care.
class NoLocalServerHost implements LocalServerHostPlatform {
  const NoLocalServerHost();

  @override
  Future<bool> isServerPc() async => false;

  @override
  String get logPath => '';

  @override
  Future<KeeperHeartbeat?> readHeartbeat() async => null;

  @override
  Future<KeeperStartOutcome> startKeeper() async => KeeperStartOutcome.missing;

  @override
  Future<bool> registerSignInStart() async => false;

  @override
  Future<KeeperSetupOutcome> runSetup() async => KeeperSetupOutcome.missing;

  @override
  Future<KeeperSetupOutcome> runKeeperElevated() async =>
      KeeperSetupOutcome.missing;
}
