import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/local_server_host.dart';
import 'package:pointy_frontend/src/features/connection/view_models/local_server_host_controller.dart';

class _FakeHost implements LocalServerHostPlatform {
  bool serverPc = true;
  KeeperStartOutcome startOutcome = KeeperStartOutcome.started;
  KeeperSetupOutcome setupOutcome = KeeperSetupOutcome.launched;
  KeeperSetupOutcome restartOutcome = KeeperSetupOutcome.launched;
  KeeperHeartbeat? heartbeat;
  Object? readError;
  Completer<KeeperSetupOutcome>? pendingRestart;
  int starts = 0;
  int signInRegistrations = 0;
  int setups = 0;
  int restarts = 0;

  @override
  Future<bool> isServerPc() async => serverPc;

  @override
  String get logPath => r'C:\ProgramData\Pointy\logs\keepalive.log';

  @override
  Future<KeeperHeartbeat?> readHeartbeat() async {
    final error = readError;
    if (error != null) {
      throw error;
    }
    return heartbeat;
  }

  @override
  Future<KeeperStartOutcome> startKeeper() async {
    starts++;
    return startOutcome;
  }

  @override
  Future<bool> registerSignInStart() async {
    signInRegistrations++;
    return true;
  }

  @override
  Future<KeeperSetupOutcome> runSetup() async {
    setups++;
    return setupOutcome;
  }

  @override
  Future<KeeperSetupOutcome> runKeeperElevated() async {
    restarts++;
    return pendingRestart?.future ?? restartOutcome;
  }
}

void main() {
  late _FakeHost host;
  late DateTime now;
  late int readyCalls;
  late LocalServerHostController controller;

  KeeperHeartbeat beat({
    bool healthy = false,
    String stage = 'STARTING',
    Duration age = Duration.zero,
  }) => KeeperHeartbeat(at: now.subtract(age), healthy: healthy, stage: stage);

  setUp(() {
    host = _FakeHost();
    now = DateTime(2026, 10, 15, 9);
    readyCalls = 0;
    controller = LocalServerHostController(
      platform: host,
      clock: () => now,
      onServerReady: () => readyCalls++,
    );
  });

  tearDown(() => controller.dispose());

  test('a PC that is not the server is left alone', () async {
    host.serverPc = false;

    await controller.start();

    expect(controller.phase, LocalServerHostPhase.inactive);
    expect(controller.showsStartingScreen, isFalse);
    expect(host.starts, 0);
    expect(host.signInRegistrations, 0);
  });

  test('opening the till starts the keeper and the sign-in start', () async {
    await controller.start();

    expect(host.starts, 1);
    expect(host.signInRegistrations, 1);
    expect(controller.phase, LocalServerHostPhase.starting);
    expect(controller.step, LocalServerStartStep.launching);
    expect(controller.showsStartingScreen, isTrue);
  });

  test('start runs once however often it is called', () async {
    await controller.start();
    await controller.start();

    expect(host.starts, 1);
  });

  test('a server already up opens the till straight away', () async {
    host
      ..startOutcome = KeeperStartOutcome.running
      ..heartbeat = beat(healthy: true, stage: 'RUNNING');

    await controller.start();

    expect(controller.phase, LocalServerHostPhase.ready);
    expect(controller.showsStartingScreen, isFalse);
    expect(readyCalls, 1);
  });

  test('follows the keeper through WSL to a ready server', () async {
    await controller.start();

    host.heartbeat = beat(stage: 'WAITING FOR WSL');
    await controller.tick();
    expect(controller.step, LocalServerStartStep.waitingForWsl);

    host.heartbeat = beat(stage: 'STARTING');
    await controller.tick();
    expect(controller.step, LocalServerStartStep.startingServices);
    expect(readyCalls, 0);

    host.heartbeat = beat(healthy: true, stage: 'RUNNING');
    await controller.tick();
    expect(controller.phase, LocalServerHostPhase.ready);
    expect(readyCalls, 1);

    // Ready stays ready without asking the connection to look again.
    await controller.tick();
    expect(readyCalls, 1);
  });

  test('starts the keeper again every minute, not every look', () async {
    await controller.start();
    now = now.add(const Duration(seconds: 30));
    await controller.tick();
    expect(host.starts, 1);

    now = now.add(const Duration(seconds: 31));
    await controller.tick();
    expect(host.starts, 2);
  });

  test(
    'a stale heartbeat is a keeper that stopped, not a ready server',
    () async {
      host.heartbeat = beat(healthy: true, stage: 'RUNNING');
      await controller.start();
      expect(controller.phase, LocalServerHostPhase.ready);

      now = now.add(const Duration(minutes: 4));
      await controller.tick();

      expect(controller.phase, LocalServerHostPhase.starting);
      expect(controller.step, LocalServerStartStep.launching);
    },
  );

  test('a heartbeat caught mid-rewrite keeps the last one', () async {
    host.heartbeat = beat(stage: 'WAITING FOR WSL');
    await controller.start();

    host.heartbeat = null;
    await controller.tick();

    expect(controller.step, LocalServerStartStep.waitingForWsl);
  });

  test('a keeper that reports a problem says so', () async {
    host.heartbeat = beat(stage: 'PROBLEM - see log');

    await controller.start();

    expect(controller.phase, LocalServerHostPhase.problem);
    expect(controller.problem, LocalServerProblem.serverNotAnswering);
    expect(controller.showsStartingScreen, isTrue);
  });

  group('a wait that goes on too long', () {
    /// [wait] passes; a keeper reporting [stage] has just written to say so.
    Future<void> after(Duration wait, {String? stage}) async {
      now = now.add(wait);
      if (stage != null) {
        host.heartbeat = beat(stage: stage);
      }
      await controller.tick();
    }

    test('a keeper that never reports is called out', () async {
      await controller.start();

      await after(const Duration(minutes: 2));
      expect(controller.phase, LocalServerHostPhase.starting);

      await after(const Duration(minutes: 1));
      expect(controller.phase, LocalServerHostPhase.problem);
      expect(controller.problem, LocalServerProblem.keeperSilent);
      // And it is still being started meanwhile.
      expect(host.starts, 3);
    });

    test('a keeper that stops reporting gets the same patience', () async {
      host.heartbeat = beat(healthy: true, stage: 'RUNNING');
      await controller.start();

      // Stale from here: three minutes of grace start now, not at the start.
      await after(const Duration(minutes: 10));
      expect(controller.phase, LocalServerHostPhase.starting);

      await after(const Duration(minutes: 3));
      expect(controller.problem, LocalServerProblem.keeperSilent);
    });

    test('WSL that does not answer is called out', () async {
      host.heartbeat = beat(stage: 'WAITING FOR WSL');
      await controller.start();

      await after(const Duration(minutes: 4), stage: 'WAITING FOR WSL');
      expect(controller.step, LocalServerStartStep.waitingForWsl);

      await after(const Duration(minutes: 1), stage: 'WAITING FOR WSL');
      expect(controller.phase, LocalServerHostPhase.problem);
      expect(controller.problem, LocalServerProblem.wslNotAnswering);
    });

    test('the server answering clears it', () async {
      await controller.start();
      await after(const Duration(minutes: 3));
      expect(controller.phase, LocalServerHostPhase.problem);

      now = now.add(const Duration(seconds: 5));
      host.heartbeat = beat(healthy: true, stage: 'RUNNING');
      await controller.tick();

      expect(controller.phase, LocalServerHostPhase.ready);
      expect(readyCalls, 1);
    });

    test('a restart runs the keeper elevated and waits afresh', () async {
      await controller.start();
      await after(const Duration(minutes: 3));

      await controller.restartServer();
      expect(host.restarts, 1);
      expect(controller.phase, LocalServerHostPhase.settingUp);

      // The restarted keeper reports; WSL gets its full patience again.
      await after(const Duration(seconds: 5), stage: 'WAITING FOR WSL');
      expect(controller.phase, LocalServerHostPhase.starting);
      expect(controller.step, LocalServerStartStep.waitingForWsl);
    });

    test(
      'the keeper a restart replaces is not taken for the new one',
      () async {
        host.heartbeat = beat(stage: 'PROBLEM - see log');
        await controller.start();
        expect(controller.phase, LocalServerHostPhase.problem);

        now = now.add(const Duration(seconds: 20));
        await controller.restartServer();
        // The stopped keeper's last word is still fresh on file.
        await after(const Duration(seconds: 5));
        expect(controller.phase, LocalServerHostPhase.settingUp);

        await after(const Duration(seconds: 5), stage: 'STARTING');
        expect(controller.phase, LocalServerHostPhase.starting);
      },
    );

    test('a restart nothing answers says so', () async {
      await controller.start();
      await after(const Duration(minutes: 3));

      await controller.restartServer();
      await after(const Duration(minutes: 3));

      expect(controller.phase, LocalServerHostPhase.problem);
      expect(controller.setupNotice, LocalServerSetupNotice.noAnswer);
    });

    test('looks keep the screen still while the prompt is open', () async {
      final prompt = Completer<KeeperSetupOutcome>();
      host.pendingRestart = prompt;
      await controller.start();
      await after(const Duration(minutes: 3));

      final restart = controller.restartServer();
      await after(const Duration(seconds: 5));
      expect(controller.phase, LocalServerHostPhase.settingUp);

      prompt.complete(KeeperSetupOutcome.cancelled);
      await restart;
      expect(controller.phase, LocalServerHostPhase.problem);
      expect(controller.setupNotice, LocalServerSetupNotice.cancelled);
    });

    test('a refused restart keeps the problem, saying why', () async {
      host.restartOutcome = KeeperSetupOutcome.cancelled;
      await controller.start();
      await after(const Duration(minutes: 3));

      await controller.restartServer();

      expect(controller.phase, LocalServerHostPhase.problem);
      expect(controller.setupNotice, LocalServerSetupNotice.cancelled);
    });
  });

  test('a task this user may not start asks for the one-time setup', () async {
    host.startOutcome = KeeperStartOutcome.denied;

    await controller.start();

    expect(controller.phase, LocalServerHostPhase.needsSetup);
  });

  test('a running keeper outranks a task this user may not see', () async {
    host
      ..startOutcome = KeeperStartOutcome.missing
      ..heartbeat = beat(stage: 'STARTING');

    await controller.start();

    expect(controller.phase, LocalServerHostPhase.starting);
  });

  test('a turned-off task is reported, not set up again', () async {
    host.startOutcome = KeeperStartOutcome.disabled;

    await controller.start();

    expect(controller.phase, LocalServerHostPhase.disabled);
  });

  group('setup', () {
    setUp(() => host.startOutcome = KeeperStartOutcome.missing);

    test('waits for the keeper it installs', () async {
      await controller.start();

      await controller.runSetup();
      expect(host.setups, 1);
      expect(controller.phase, LocalServerHostPhase.settingUp);

      // -Install has started the task; the next look starts it again at once.
      host
        ..startOutcome = KeeperStartOutcome.running
        ..heartbeat = beat(stage: 'WAITING FOR WSL');
      now = now.add(const Duration(seconds: 5));
      await controller.tick();
      expect(host.starts, 2);
      expect(controller.phase, LocalServerHostPhase.starting);
    });

    test('a refused prompt asks again, saying why', () async {
      host.setupOutcome = KeeperSetupOutcome.cancelled;
      await controller.start();

      await controller.runSetup();

      expect(controller.phase, LocalServerHostPhase.needsSetup);
      expect(controller.setupNotice, LocalServerSetupNotice.cancelled);
    });

    test('a setup that never reports goes back to asking', () async {
      await controller.start();
      await controller.runSetup();

      now = now.add(const Duration(minutes: 4));
      await controller.tick();

      expect(controller.phase, LocalServerHostPhase.needsSetup);
    });
  });

  test('a look that fails keeps the looking going', () async {
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);
    controller = LocalServerHostController(
      platform: host,
      clock: () => now,
      pollWhileWaiting: const Duration(milliseconds: 1),
    );

    host.readError = StateError('disk gone');
    await controller.start();
    expect(reported, hasLength(1));

    host
      ..readError = null
      ..heartbeat = beat(healthy: true, stage: 'RUNNING');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.phase, LocalServerHostPhase.ready);
  });

  test('choosing another server hands the screen back to the gate', () async {
    await controller.start();

    controller.connectElsewhere();

    expect(controller.showsStartingScreen, isFalse);
    // The keeper is still looked after.
    now = now.add(const Duration(minutes: 1));
    await controller.tick();
    expect(host.starts, 2);
  });
}
