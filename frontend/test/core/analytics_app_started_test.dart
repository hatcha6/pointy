/// What a launch was, on what machine.
///
/// `app.started` was recorded 4,126 times in the field export and carried no
/// payload whatsoever: no duration, no version, nothing about the hardware. So
/// "the tills take forever to open in the morning" had no number attached to
/// it, a fleet of machines a decade apart in age was one undifferentiated mass,
/// and not one row could be tied to the build it came from.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_device_profile.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';

const AnalyticsDeviceProfile _tillProfile = AnalyticsDeviceProfile(
  appVersion: '0.5.9',
  versionSource: 'define',
  attributes: {
    'os': 'windows',
    'os_version': '10.0.19045',
    'cpu_model': 'Intel64 Family 6 Model 142 Stepping 10, GenuineIntel',
    'cpu_arch': 'AMD64',
    'host_name': 'TILL-02',
  },
  metrics: {
    'cpu_cores': 2,
    'ram_total_mb': 3891,
    'ram_available_mb': 612,
    'screen_width_px': 1366,
    'screen_height_px': 768,
    'device_pixel_ratio': 1.0,
  },
);

void main() {
  late _FakeAnalyticsSink sink;

  setUp(() => sink = _FakeAnalyticsSink());

  AnalyticsEngine engineFor(
    MemoryAnalyticsQueueStorage storage, {
    Future<AnalyticsDeviceProfile> Function()? profile,
    Duration uptime = const Duration(milliseconds: 8400),
    Duration profileTimeout = const Duration(seconds: 5),
    String appVersion = '',
    void Function(String deviceId, String platform, String appVersion)?
    onIdentityResolved,
  }) {
    return AnalyticsEngine(
      sink,
      storage: storage,
      flushInterval: const Duration(hours: 1),
      appVersion: appVersion,
      deviceProfile: profile ?? (() async => _tillProfile),
      deviceProfileTimeout: profileTimeout,
      uptime: () => uptime,
      onIdentityResolved: onIdentityResolved,
    )..setCurrentUser(7);
  }

  AnalyticsEventDraft launchIn(List<AnalyticsEventDraft> events) {
    return events.firstWhere((event) => event.name == 'app.started');
  }

  group('a launch describes itself', () {
    test('it says how long the till took to come up', () async {
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
        uptime: const Duration(milliseconds: 8400),
      );

      await engine.start();

      // The number that did not exist. Process start to a running app with
      // live telemetry: the preference repair, the key/value store and the
      // queue read, which is the disk work that makes a cold till slow.
      expect(launchIn(sink.acceptedEvents).metrics['duration_ms'], 8400);
      engine.dispose();
    });

    test('it says what machine it happened on', () async {
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
      );

      await engine.start();

      final launch = launchIn(sink.acceptedEvents);
      expect(launch.attributes['cpu_model'], contains('Intel64'));
      expect(launch.attributes['host_name'], 'TILL-02');
      expect(launch.metrics['ram_total_mb'], 3891);
      expect(launch.metrics['cpu_cores'], 2);
      expect(launch.metrics['screen_width_px'], 1366);
      expect(
        launch.metrics['screen_height_px'],
        768,
        reason: 'a 2-core 4GB machine on a 1366x768 panel is a finding, not '
            'trivia: "the till is slow" and "the till is old" were '
            'indistinguishable',
      );
      engine.dispose();
    });

    test('the backlog it arrived holding is counted before it adds to it',
        () async {
      final storage = MemoryAnalyticsQueueStorage(
        installationId: 'till-2',
        events: List.generate(
          4,
          (index) => AnalyticsEventDraft.usage(
            AnalyticsEventName.posCheckoutCompleted,
          ),
        ),
      );

      final engine = engineFor(storage);
      await engine.start();

      expect(launchIn(sink.acceptedEvents).metrics['backlog_at_start'], 4);
      engine.dispose();
    });
  });

  group('a build names itself even when nothing was injected', () {
    test('the bundle version stands in for a missing define', () async {
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
        appVersion: '',
        profile: () async => const AnalyticsDeviceProfile(
          appVersion: '0.5.2',
          versionSource: 'package',
        ),
      );

      await engine.start();
      await engine.trackUsage(AnalyticsEventName.posCheckoutCompleted);
      await engine.flush();

      // Not just on the launch event: the whole point is that every row can be
      // tied back to a build.
      expect(
        sink.acceptedEvents.map((event) => event.appVersion).toSet(),
        {'0.5.2'},
      );
      expect(launchIn(sink.acceptedEvents).attributes['version_source'],
          'package');
      engine.dispose();
    });

    test('an injected define is not overridden by the bundle', () async {
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
        appVersion: '0.5.9',
      );

      await engine.start();

      expect(launchIn(sink.acceptedEvents).attributes['app_version'], '0.5.9');
      expect(
        launchIn(sink.acceptedEvents).attributes['version_source'],
        'define',
      );
      engine.dispose();
    });

    test('a device that can say nothing claims nothing', () async {
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
        appVersion: '',
        profile: () async => AnalyticsDeviceProfile.unknown,
      );

      await engine.start();

      expect(
        sink.acceptedEvents.every((event) => event.appVersion == null),
        isTrue,
        reason: 'a blank column is honest; an invented version is not',
      );
      expect(
        launchIn(sink.acceptedEvents).attributes['version_source'],
        'unknown',
      );
      engine.dispose();
    });

    test('the API session is told the version the bundle resolved', () async {
      final announced = <String>[];
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
        appVersion: '',
        profile: () async => const AnalyticsDeviceProfile(
          appVersion: '0.5.2',
          versionSource: 'package',
        ),
        onIdentityResolved: (deviceId, platform, appVersion) =>
            announced.add(appVersion),
      );

      await engine.start();

      // Announced twice on purpose: once immediately so a request made during
      // startup still names its device, and again once the bundle answers.
      expect(announced, ['', '0.5.2']);
      engine.dispose();
    });
  });

  group('a launch says which kind of launch it is', () {
    test('a fresh install says so', () async {
      final engine = engineFor(MemoryAnalyticsQueueStorage());

      await engine.start();

      expect(launchIn(sink.acceptedEvents).attributes['start_type'],
          'first_run');
      engine.dispose();
    });

    test('the first morning on a new build says so, and says what it left',
        () async {
      // The fact a week of telemetry could not produce: a shop was running
      // 0.5.2 while the tags had reached 0.5.9, and nothing marked the moment
      // a till changed build — so a regression and a rollout could not be
      // lined up against each other.
      final storage = MemoryAnalyticsQueueStorage(
        installationId: 'till-2',
        lastAppVersion: '0.5.2',
      );

      final engine = engineFor(storage, appVersion: '0.5.9');
      await engine.start();

      final launch = launchIn(sink.acceptedEvents);
      expect(launch.attributes['start_type'], 'update');
      expect(launch.attributes['previous_version'], '0.5.2');
      expect(await storage.loadLastAppVersion(), '0.5.9');
      engine.dispose();
    });

    test('an ordinary morning is just a cold start', () async {
      final storage = MemoryAnalyticsQueueStorage(
        installationId: 'till-2',
        lastAppVersion: '0.5.9',
      );

      final engine = engineFor(storage, appVersion: '0.5.9');
      await engine.start();

      final launch = launchIn(sink.acceptedEvents);
      expect(launch.attributes['start_type'], 'cold');
      expect(launch.attributes.containsKey('previous_version'), isFalse);
      engine.dispose();
    });

    test('a device that never recorded a version does not invent an update',
        () async {
      // Every till in the fleet hits this exactly once, on the first launch
      // after the build that started recording versions. Calling that an
      // update would show the whole fleet updating on a day none of them did.
      final storage = MemoryAnalyticsQueueStorage(installationId: 'till-2');

      final engine = engineFor(storage, appVersion: '0.5.9');
      await engine.start();

      expect(launchIn(sink.acceptedEvents).attributes['start_type'], 'cold');
      engine.dispose();
    });
  });

  group('reading the machine can never cost the launch', () {
    test('a profile that never answers is given up on', () async {
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
        appVersion: '0.5.9',
        profileTimeout: const Duration(milliseconds: 20),
        profile: () => Future<AnalyticsDeviceProfile>.delayed(
          const Duration(seconds: 30),
          () => _tillProfile,
        ),
      );

      await engine.start();

      final launch = launchIn(sink.acceptedEvents);
      expect(launch.attributes['app_version'], '0.5.9');
      expect(
        launch.metrics.containsKey('ram_total_mb'),
        isFalse,
        reason: 'what could not be read is absent, not guessed',
      );
      expect(launch.metrics['duration_ms'], isNotNull);
      engine.dispose();
    });

    test('a profile that throws is survived', () async {
      final engine = engineFor(
        MemoryAnalyticsQueueStorage(installationId: 'till-2'),
        appVersion: '0.5.9',
        profile: () async => throw StateError('no platform channel'),
      );

      await engine.start();

      expect(launchIn(sink.acceptedEvents).attributes['start_type'], 'cold');
      engine.dispose();
    });
  });
}

class _FakeAnalyticsSink implements AnalyticsEventSink {
  final List<AnalyticsEventDraft> acceptedEvents = [];

  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async {
    acceptedEvents.addAll(events);
    return Ok(
      AnalyticsIngestResult(
        accepted: events.length,
        duplicates: 0,
        eventIds: events.map((event) => event.clientEventId).toList(),
      ),
    );
  }
}
