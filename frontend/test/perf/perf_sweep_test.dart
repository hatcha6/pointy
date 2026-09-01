// Frontend performance sweep — hermetic replay.
//
// Drives the real app (real screens, real view models, real parsing) through
// every screen and dialog against recorded backend responses, and measures
// each frame's structural cost: widgets rebuilt, render objects painted, the
// window area re-recorded, saveLayer-class layers. These numbers are the same
// on any hardware, which is the point: the shop PCs that jank are not on the
// desk.
//
//   flutter test test/perf/perf_sweep_test.dart
//
// Environment:
//   PERF_FIXTURE=<file>   recorded responses (default test/perf/fixtures/sweep.json)
//   PERF_SURFACES=a,b     only these surfaces
//   PERF_LATENCY_MS=250   simulated backend round-trip (keeps loading states measurable)
//   PERF_OUT=<dir>        report directory (default build/perf)
//   PERF_STRICT=1         fail the test on any FAIL verdict
//
// Record the fixture with the live entrypoint (lib/dev/perf_sweep.dart) in
// record mode against a running backend.
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/perf/frame_probe.dart';
import 'package:pointy_frontend/dev/perf/replay_http_client.dart';
import 'package:pointy_frontend/dev/perf/sweep_driver.dart';
import 'package:pointy_frontend/dev/perf/sweep_report.dart';
import 'package:pointy_frontend/dev/perf/sweep_script.dart';
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

import '../support/key_value_store_testing.dart';

void main() {
  final env = Platform.environment;
  final fixturePath = env['PERF_FIXTURE'] ?? 'test/perf/fixtures';
  final only = (env['PERF_SURFACES'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final latency = Duration(
    milliseconds: int.tryParse(env['PERF_LATENCY_MS'] ?? '') ?? 250,
  );
  final outDir = Directory(env['PERF_OUT'] ?? 'build/perf');
  final strict = env['PERF_STRICT'] == '1';

  testWidgets('every screen and dialog stays within the frame budget', (
    tester,
  ) async {
    installMemoryKeyValueStore();
    // A typical shop PC: Windows, 1366×768 at 1×. The platform matters for
    // scroll physics and overscroll (Android's stretch effect is a saveLayer
    // the shop machines never pay for).
    // Reset before the test body returns: the binding verifies foundation
    // debug variables before tear-downs run.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixtureFile = File(fixturePath);
    final fixtureDir = Directory(fixturePath);
    final store = fixtureDir.existsSync()
        ? PerfFixtureStore.loadDirectory(fixtureDir)
        : PerfFixtureStore.load(fixtureFile);
    final client = ReplayHttpClient(store, latency: latency);
    final service = PosApiService(
      client: client,
      baseUrl: 'http://127.0.0.1:8000/api',
    );
    final probe = FrameProbe()..start();

    await tester.pumpWidget(PointyApp(apiService: service));

    final driver = SweepDriver(
      controller: tester,
      probe: probe,
      pumpFrame: (duration) => tester.pump(duration),
      log: (message) => debugPrint('[perf] $message'),
      takeException: tester.takeException,
    );
    await driver.settle(timeout: const Duration(seconds: 20));
    // Replay lands on the login screen (the session probe was recorded as a
    // 401 before sign-in); the sweep's `login` surface signs in — measured —
    // with the recorded login answer.
    try {
      await runSweep(driver, only: only);
    } finally {
      probe.finish();
      final bp = FrameProbe.debugBoundaryPaints.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
      for (final e in bp.take(25)) { stderr.writeln('BOUNDARY ${e.value} ${e.key}'); }
      debugDefaultTargetPlatformOverride = null;
    }

    final report = SweepReport.build(
      probe,
      driver,
      misses: client.misses,
      mode: 'replay/${store.entries.isNotEmpty ? 'fixture' : 'NO FIXTURE'}',
      // `flutter test` is a debug build: timings are not meaningful here.
      judgeTimings: false,
    );
    outDir.createSync(recursive: true);
    File('${outDir.path}/sweep_report.md').writeAsStringSync(
      report.toMarkdown(),
    );
    File('${outDir.path}/sweep_report.json').writeAsStringSync(
      report.toJsonString(),
    );
    debugPrint(
      '[perf] ${report.failures.length} FAIL, ${report.warnings.length} WARN '
      'across ${report.summaries.length} phases → ${outDir.path}/sweep_report.md',
    );
    for (final failure in report.failures) {
      debugPrint('[perf] FAIL ${failure.key}: ${failure.reasons.join('; ')}');
    }
    if (strict) {
      expect(
        report.failures.map((s) => '${s.key}: ${s.reasons.join('; ')}'),
        isEmpty,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
