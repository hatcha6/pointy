// Dev-only entrypoint: runs the performance sweep inside a real build of the
// app (safe to delete; never imported by lib/main.dart).
//
// Two jobs:
//
// 1. Record fixtures against a running backend, so the hermetic
//    `flutter test test/perf/perf_sweep_test.dart` sweep replays real payloads.
//    Use `make frontend-perf-record` (it serialises concurrent recorders and
//    passes the right paths), or by hand:
//
//      flutter run -d macos -t lib/dev/perf_sweep.dart \
//        --dart-define=PERF_MODE=record \
//        --dart-define=PERF_FIXTURE_DIR=/abs/path/test/perf/fixtures \
//        --dart-define=PERF_FIXTURE=/abs/path/test/perf/fixtures/<area>.json \
//        --dart-define=PERF_SURFACES=invoices,invoice_details
//
//    Every fixture file in PERF_FIXTURE_DIR is loaded first (so replayable
//    answers are known), and only the responses newly recorded by this run
//    are appended to PERF_FIXTURE.
//
// 2. Measure real build/raster times in a profile build (replaying the
//    fixtures, so it needs no backend): `make frontend-perf-profile`, or:
//
//      flutter run -d macos --profile -t lib/dev/perf_sweep.dart \
//        --dart-define=PERF_FIXTURE_DIR=/abs/path/test/perf/fixtures \
//        --dart-define=PERF_OUT=/abs/path/build/perf_profile
//
// The process exits when the sweep is done; the report lands in PERF_OUT.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart' show LiveWidgetController;
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/pos_http_client.dart';

import 'perf/frame_probe.dart';
import 'perf/replay_http_client.dart';
import 'perf/sweep_driver.dart';
import 'perf/sweep_report.dart';
import 'perf/sweep_script.dart';

const _mode = String.fromEnvironment('PERF_MODE', defaultValue: 'replay');
const _fixtureDir = String.fromEnvironment(
  'PERF_FIXTURE_DIR',
  defaultValue: 'test/perf/fixtures',
);
const _fixturePath = String.fromEnvironment(
  'PERF_FIXTURE',
  defaultValue: 'test/perf/fixtures/sweep.json',
);
const _outDir = String.fromEnvironment('PERF_OUT', defaultValue: 'build/perf');
const _baseUrl = String.fromEnvironment(
  'PERF_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000/api',
);
const _username = String.fromEnvironment('PERF_USER', defaultValue: 'perf');
const _password = String.fromEnvironment(
  'PERF_PASSWORD',
  defaultValue: 'perfperf',
);
const _surfaces = String.fromEnvironment('PERF_SURFACES', defaultValue: '');
const _latencyMs = int.fromEnvironment('PERF_LATENCY_MS', defaultValue: 0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = PerfFixtureStore.loadDirectory(Directory(_fixtureDir));
  final recording = _mode == 'record';
  final baseline = store.snapshot();
  final RecordingHttpClient? recorder = recording
      ? RecordingHttpClient(createPosHttpClient(), store)
      : null;
  final ReplayHttpClient? replayer = recording
      ? null
      : ReplayHttpClient(
          store,
          latency: Duration(milliseconds: _latencyMs),
        );
  final service = PosApiService(
    client: recorder ?? replayer!,
    baseUrl: _baseUrl,
  );
  final probe = FrameProbe()..start();
  runApp(PointyApp(apiService: service));

  final controller = LiveWidgetController(WidgetsBinding.instance);
  final driver = SweepDriver(
    controller: controller,
    probe: probe,
    pumpFrame: (duration) => controller.pump(duration),
    log: (message) => debugPrint('[perf] $message'),
  );
  // Let the first frame and the auth check land before driving. The sweep's
  // `login` surface signs in (measured); replay lands on the login screen
  // too, since the session probe was recorded before sign-in, and the login
  // answer is in the fixture.
  await driver.settle(timeout: const Duration(seconds: 30));
  if (_username != 'perf' || _password != 'perfperf') {
    await driver.login(_username, _password);
  }
  final only = _surfaces
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  await runSweep(driver, only: only);
  probe.finish();

  if (recorder != null) {
    final fixtureFile = File(_fixturePath);
    final own = PerfFixtureStore.load(fixtureFile);
    final fresh = store.diff(baseline);
    for (final entry in fresh.entries.entries) {
      final list = own.entries.putIfAbsent(entry.key, () => []);
      list.addAll(entry.value);
    }
    own.save(fixtureFile);
    debugPrint(
      '[perf] recorded ${recorder.recorded} responses, '
      '${fresh.entries.length} new keys → ${fixtureFile.path}',
    );
  }
  final report = SweepReport.build(
    probe,
    driver,
    misses: replayer?.misses ?? const [],
    mode: recording
        ? 'record/${kDebugMode ? 'debug' : 'profile'}'
        : 'replay/${kDebugMode ? 'debug' : 'profile'}',
    judgeTimings: !kDebugMode,
  );
  final out = Directory(_outDir)..createSync(recursive: true);
  File('${out.path}/sweep_report.md').writeAsStringSync(report.toMarkdown());
  File('${out.path}/sweep_report.json').writeAsStringSync(
    report.toJsonString(),
  );
  debugPrint(
    '[perf] ${report.failures.length} FAIL, ${report.warnings.length} WARN '
    'across ${report.summaries.length} phases → ${out.path}/sweep_report.md',
  );
  debugPrint('[perf] PERF_SWEEP_DONE');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  exit(0);
}
