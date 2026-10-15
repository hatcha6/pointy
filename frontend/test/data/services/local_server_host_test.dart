import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/local_server_host.dart';
import 'package:pointy_frontend/src/data/services/local_server_host_io.dart';

void main() {
  group('KeeperHeartbeat.parse', () {
    test('reads what Windows PowerShell writes, byte-order mark included', () {
      final heartbeat = KeeperHeartbeat.parse(
        '\uFEFF{\r\n    "healthy":  true,\r\n    "stage":  "RUNNING",\r\n'
        '    "heartbeat_at":  "2026-10-15T09:30:12.1234567+02:00",\r\n'
        '    "keeper_pid":  4120\r\n}',
      );

      expect(heartbeat, isNotNull);
      expect(heartbeat!.healthy, isTrue);
      expect(heartbeat.stage, 'RUNNING');
      expect(
        heartbeat.at.toUtc(),
        DateTime.utc(2026, 10, 15, 7, 30, 12, 123, 456),
      );
    });

    test('a keeper older than the client start has no stage', () {
      final heartbeat = KeeperHeartbeat.parse(
        '{"healthy": false, "heartbeat_at": "2026-10-15T09:30:12+02:00"}',
      );

      expect(heartbeat!.stage, '');
      expect(heartbeat.reportsProblem, isFalse);
    });

    test('names the stages the client shows', () {
      KeeperHeartbeat at(String stage) =>
          KeeperHeartbeat(at: DateTime(2026), healthy: false, stage: stage);

      expect(at('PROBLEM - see log').reportsProblem, isTrue);
      expect(at('WAITING FOR WSL').waitingForWsl, isTrue);
      expect(at('STARTING').reportsProblem, isFalse);
    });

    test('a file caught mid-rewrite is no heartbeat', () {
      expect(KeeperHeartbeat.parse('{"healthy": tr'), isNull);
      expect(KeeperHeartbeat.parse(''), isNull);
      expect(KeeperHeartbeat.parse('[]'), isNull);
      expect(KeeperHeartbeat.parse('{"healthy": true}'), isNull);
    });
  });

  test('start outcomes from the runner', () {
    expect(KeeperStartOutcome.parse('started'), KeeperStartOutcome.started);
    expect(KeeperStartOutcome.parse('running'), KeeperStartOutcome.running);
    expect(KeeperStartOutcome.parse('denied').needsSetup, isTrue);
    expect(KeeperStartOutcome.parse('missing').needsSetup, isTrue);
    expect(KeeperStartOutcome.parse('disabled'), KeeperStartOutcome.disabled);
    expect(KeeperStartOutcome.parse(null), KeeperStartOutcome.failed);
    expect(KeeperStartOutcome.parse('surprise').needsSetup, isFalse);
  });

  test('setup outcomes from the runner', () {
    expect(KeeperSetupOutcome.parse('launched'), KeeperSetupOutcome.launched);
    expect(KeeperSetupOutcome.parse('cancelled'), KeeperSetupOutcome.cancelled);
    expect(KeeperSetupOutcome.parse('missing'), KeeperSetupOutcome.missing);
    expect(KeeperSetupOutcome.parse(null), KeeperSetupOutcome.failed);
  });

  group('WindowsLocalServerHost.isServerPc', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('pointy/server_host');
    late Directory programData;
    late bool distroRegistered;
    late int distroLookups;

    setUp(() {
      programData = Directory.systemTemp.createTempSync('program-data-');
      Directory(
        '${programData.path}${Platform.pathSeparator}Pointy',
      ).createSync();
      distroRegistered = false;
      distroLookups = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'hasDistro') {
              distroLookups++;
              return distroRegistered;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      programData.deleteSync(recursive: true);
    });

    WindowsLocalServerHost host() =>
        WindowsLocalServerHost(programData: programData.path);
    void leave(String name) => File(
      [programData.path, 'Pointy', name].join(Platform.pathSeparator),
    ).writeAsStringSync('x');

    test('an installed keeper marks the server PC', () async {
      leave('keep-pointy-running.ps1');

      expect(await host().isServerPc(), isTrue);
      expect(distroLookups, 0);
    });

    test('so does an install that never set the keeper up', () async {
      leave('bootstrap-wsl.ps1');

      expect(await host().isServerPc(), isTrue);
    });

    test('with no files, WSL registration decides', () async {
      expect(await host().isServerPc(), isFalse);

      distroRegistered = true;
      expect(await host().isServerPc(), isTrue);
    });

    test('a server moved to Linux is not one any more', () async {
      leave('keep-pointy-running.ps1');
      leave('MOVED-TO-LINUX.txt');
      distroRegistered = true;

      expect(await host().isServerPc(), isFalse);
    });
  });
}
