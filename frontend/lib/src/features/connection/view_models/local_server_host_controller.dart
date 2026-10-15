import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/services/local_server_host.dart';

/// Where this PC's own server stands, as the till on the shop's WSL server PC
/// sees it.
enum LocalServerHostPhase {
  /// Not the server PC (or not looked yet): nothing to show.
  inactive,

  /// The keeper is being started, or is starting WSL and the stack.
  starting,

  /// The server answers on the path a till takes.
  ready,

  /// Waiting has gone on too long; [LocalServerHostController.problem] says
  /// what is stuck. Everything keeps retrying meanwhile.
  problem,

  /// The keeper's task is missing, or this user may not start it: the
  /// one-time administrator setup puts that right.
  needsSetup,

  /// The setup, or a restart, was launched; waiting for the keeper to
  /// report.
  settingUp,

  /// The keeper's task is turned off.
  disabled,
}

/// The step [LocalServerHostPhase.starting] is at.
enum LocalServerStartStep { launching, waitingForWsl, startingServices }

/// What is stuck, in [LocalServerHostPhase.problem].
enum LocalServerProblem {
  /// The keeper was started but has written no heartbeat: Windows accepted
  /// the start and nothing ran, or it stopped.
  keeperSilent,

  /// The keeper runs, but WSL itself does not answer.
  wslNotAnswering,

  /// WSL runs, but the server has not answered for minutes.
  serverNotAnswering,
}

/// Why the last setup or restart did not bring the keeper up.
enum LocalServerSetupNotice {
  none,
  cancelled,
  missing,
  failed,

  /// It launched, but no keeper reported within [LocalServerHostController.
  /// setupPatience]: the elevated script stopped early (its log says why).
  noAnswer,
}

/// Keeps the shop's WSL server running from the till on the same PC.
///
/// WSL powers the server's distro off once nothing on Windows holds it, and
/// only an elevated keeper can also re-point the LAN forward, so the server
/// lives in `keep-pointy-running.ps1`'s scheduled task. This controller is what
/// makes sure that task runs: it starts it when the till opens and every
/// [kickEvery] after, registers the sign-in start (`--start-server`), and
/// reads the keeper's heartbeat so the connection gate can tell the cashier
/// what is happening instead of "searching for the server". Closing the till
/// leaves the keeper, and the server, running.
class LocalServerHostController extends ChangeNotifier {
  LocalServerHostController({
    required LocalServerHostPlatform platform,
    this.onServerReady,
    DateTime Function()? clock,
    this.pollWhileWaiting = const Duration(seconds: 5),
    this.pollWhileReady = const Duration(seconds: 30),
    this.kickEvery = const Duration(minutes: 1),
    this.heartbeatFreshFor = const Duration(minutes: 3),
    this.setupPatience = const Duration(minutes: 3),
    this.keeperSilentAfter = const Duration(minutes: 3),
    this.wslPatience = const Duration(minutes: 5),
  }) : _platform = platform,
       _clock = clock ?? DateTime.now;

  final LocalServerHostPlatform _platform;
  final DateTime Function() _clock;

  /// Called when the server turns ready, so a connection that gave up looks
  /// again at once rather than on its own schedule.
  final VoidCallback? onServerReady;

  final Duration pollWhileWaiting;
  final Duration pollWhileReady;

  /// Starting a task that already runs is a no-op, so this is cheap; it is
  /// what brings the keeper back within a minute if it ever stops.
  final Duration kickEvery;

  /// The keeper writes its heartbeat about once a minute, but a cycle that
  /// waits on WSL or the stack can run for minutes.
  final Duration heartbeatFreshFor;

  /// How long a launched setup may take to produce a heartbeat before the
  /// screen goes back to asking for it.
  final Duration setupPatience;

  /// How long the keeper may stay silent before the screen says so. Its first
  /// heartbeat comes within seconds of it starting.
  final Duration keeperSilentAfter;

  /// How long WSL may take to answer. It boots in seconds; minutes is a WSL
  /// that is broken or being updated.
  final Duration wslPatience;

  LocalServerHostPhase _phase = LocalServerHostPhase.inactive;
  LocalServerStartStep _step = LocalServerStartStep.launching;
  LocalServerProblem _problem = LocalServerProblem.serverNotAnswering;
  LocalServerSetupNotice _setupNotice = LocalServerSetupNotice.none;
  KeeperStartOutcome? _lastStart;
  KeeperHeartbeat? _heartbeat;
  DateTime? _lastKick;
  DateTime? _setupLaunchedAt;
  // Since when there has been no fresh heartbeat, and since when the keeper
  // has been waiting for WSL; null while that is not so.
  DateTime? _silentSince;
  DateTime? _wslWaitSince;
  bool _started = false;
  bool _ticking = false;
  // An administrator prompt is open: looks keep reading, but the screen stays
  // on "setting up" until it is answered.
  bool _launching = false;
  bool _dismissed = false;
  bool _disposed = false;
  Timer? _timer;

  LocalServerHostPhase get phase => _phase;
  LocalServerStartStep get step => _step;
  LocalServerProblem get problem => _problem;
  LocalServerSetupNotice get setupNotice => _setupNotice;
  String get logPath => _platform.logPath;

  /// The connection gate shows the server-starting screen instead of its own
  /// while this holds.
  bool get showsStartingScreen =>
      !_dismissed &&
      _phase != LocalServerHostPhase.inactive &&
      _phase != LocalServerHostPhase.ready;

  /// Safe to call more than once; only the first call does anything.
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    if (!await _platform.isServerPc() || _disposed) {
      return;
    }
    unawaited(_platform.registerSignInStart());
    await tick();
  }

  /// One look: start the keeper when it is due, read its heartbeat, and
  /// schedule the next look. Public for tests; the timer drives it otherwise.
  @visibleForTesting
  Future<void> tick() async {
    if (_disposed || _ticking) {
      return;
    }
    _ticking = true;
    _timer?.cancel();
    try {
      final now = _clock();
      final lastKick = _lastKick;
      if (lastKick == null || now.difference(lastKick) >= kickEvery) {
        _lastKick = now;
        _lastStart = await _platform.startKeeper();
      }
      final heartbeat = await _platform.readHeartbeat();
      // A heartbeat caught mid-rewrite reads as null; the last one stands.
      if (heartbeat != null) {
        _heartbeat = heartbeat;
      }
      if (!_disposed && !_launching) {
        _apply(now);
      }
    } catch (error, stack) {
      // One failed look must not end the looking: the keeper is kicked from
      // here, and nothing else would start it again until the till reopens.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'local server host',
        ),
      );
    } finally {
      _ticking = false;
      _schedule();
    }
  }

  /// The one-time administrator setup: re-installs the keeper's task so
  /// signed-in users may start it, and starts it.
  Future<void> runSetup() => _launchElevated(_platform.runSetup);

  /// The last resort: one administrator prompt, then the keeper restarts
  /// itself and WSL, and runs in this session even when its task will not.
  /// It is what staff did by hand, an elevated PowerShell with `wsl` in it, as
  /// a button.
  Future<void> restartServer() => _launchElevated(_platform.runKeeperElevated);

  Future<void> _launchElevated(
    Future<KeeperSetupOutcome> Function() launch,
  ) async {
    if (_disposed || _phase == LocalServerHostPhase.settingUp) {
      return;
    }
    _setupNotice = LocalServerSetupNotice.none;
    _phase = LocalServerHostPhase.settingUp;
    _launching = true;
    notifyListeners();
    KeeperSetupOutcome outcome;
    try {
      outcome = await launch();
    } catch (_) {
      outcome = KeeperSetupOutcome.failed;
    } finally {
      _launching = false;
    }
    if (_disposed) {
      return;
    }
    switch (outcome) {
      case KeeperSetupOutcome.launched:
        final now = _clock();
        _setupLaunchedAt = now;
        // A fresh start: the waits are counted again from here.
        if (_silentSince != null) {
          _silentSince = now;
        }
        if (_wslWaitSince != null) {
          _wslWaitSince = now;
        }
        // Look again soon after; starting the task again is harmless.
        _lastKick = null;
      case KeeperSetupOutcome.cancelled:
        _setupNotice = LocalServerSetupNotice.cancelled;
      case KeeperSetupOutcome.missing:
        _setupNotice = LocalServerSetupNotice.missing;
      case KeeperSetupOutcome.failed:
        _setupNotice = LocalServerSetupNotice.failed;
    }
    _apply(_clock());
    _schedule();
  }

  /// The cashier chose another server: the gate's own screens take over. The
  /// keeper is still started every minute.
  void connectElsewhere() {
    if (_dismissed) {
      return;
    }
    _dismissed = true;
    notifyListeners();
  }

  void _apply(DateTime now) {
    final previous = (_phase, _step, _problem, _setupNotice);
    final heartbeat = _heartbeat;
    final setupLaunchedAt = _setupLaunchedAt;
    final settingUp =
        setupLaunchedAt != null &&
        now.difference(setupLaunchedAt) < setupPatience;
    // While a launch is awaited, only what the launched keeper writes counts:
    // the keeper it replaces may still have a fresh "PROBLEM" on file.
    final fresh =
        heartbeat != null &&
        now.difference(heartbeat.at) < heartbeatFreshFor &&
        !(settingUp && heartbeat.at.isBefore(setupLaunchedAt));
    if (fresh) {
      _setupLaunchedAt = null;
      _silentSince = null;
    } else {
      _silentSince ??= now;
      if (setupLaunchedAt != null && !settingUp) {
        // Launched, and nothing answered in time.
        _setupLaunchedAt = null;
        _setupNotice = LocalServerSetupNotice.noAnswer;
      }
    }
    if (fresh && heartbeat.waitingForWsl) {
      _wslWaitSince ??= now;
    } else {
      _wslWaitSince = null;
    }
    bool waitedFor(DateTime? since, Duration patience) =>
        since != null && now.difference(since) >= patience;

    if (fresh && heartbeat.healthy) {
      _phase = LocalServerHostPhase.ready;
    } else if (fresh && heartbeat.reportsProblem) {
      _setProblem(LocalServerProblem.serverNotAnswering);
    } else if (fresh && waitedFor(_wslWaitSince, wslPatience)) {
      _setProblem(LocalServerProblem.wslNotAnswering);
    } else if (fresh) {
      _phase = LocalServerHostPhase.starting;
      _step = heartbeat.waitingForWsl
          ? LocalServerStartStep.waitingForWsl
          : LocalServerStartStep.startingServices;
    } else if (settingUp) {
      _phase = LocalServerHostPhase.settingUp;
    } else if (_lastStart?.needsSetup ?? false) {
      _phase = LocalServerHostPhase.needsSetup;
    } else if (_lastStart == KeeperStartOutcome.disabled) {
      _phase = LocalServerHostPhase.disabled;
    } else if (waitedFor(_silentSince, keeperSilentAfter)) {
      _setProblem(LocalServerProblem.keeperSilent);
    } else {
      _phase = LocalServerHostPhase.starting;
      _step = LocalServerStartStep.launching;
    }
    if (_phase != LocalServerHostPhase.needsSetup &&
        _phase != LocalServerHostPhase.problem &&
        _phase != LocalServerHostPhase.settingUp) {
      _setupNotice = LocalServerSetupNotice.none;
    }

    if ((_phase, _step, _problem, _setupNotice) == previous) {
      return;
    }
    notifyListeners();
    if (_phase == LocalServerHostPhase.ready &&
        previous.$1 != LocalServerHostPhase.ready) {
      onServerReady?.call();
    }
  }

  void _setProblem(LocalServerProblem problem) {
    _phase = LocalServerHostPhase.problem;
    _problem = problem;
  }

  void _schedule() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      _phase == LocalServerHostPhase.ready ? pollWhileReady : pollWhileWaiting,
      () => unawaited(tick()),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
