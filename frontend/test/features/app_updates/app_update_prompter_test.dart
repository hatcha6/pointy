import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/client_update_service.dart';
import 'package:pointy_frontend/src/features/app_updates/view_models/app_update_prompter.dart';

ClientRelease _release(String version) => ClientRelease(
  version: version,
  file: 'pointy-$version-android-universal.apk',
  sha256: '',
  size: 80 * 1024 * 1024,
  url: '/clients/files/pointy-$version-android-universal.apk',
);

/// A manifest the test can republish, and a count of how often it was read.
class _Manifest {
  String running = '0.7.9';
  String? offered;
  int reads = 0;

  Future<ClientUpdateStatus> check() async {
    reads += 1;
    final offered = this.offered;
    return ClientUpdateStatus(
      currentVersion: running,
      platform: ClientPlatform.android,
      available: offered != null && isNewerVersion(offered, running)
          ? _release(offered)
          : null,
    );
  }
}

void main() {
  late _Manifest manifest;
  late ValueNotifier<String?> serverVersion;
  late String? postponed;
  late AppUpdatePrompter prompter;

  AppUpdatePrompter build({List<Duration>? retryDelays}) => AppUpdatePrompter(
    check: manifest.check,
    serverVersion: serverVersion,
    loadPostponed: () async => postponed,
    savePostponed: (version) async => postponed = version,
    retryDelays: retryDelays ?? AppUpdatePrompter.defaultRetryDelays,
  );

  setUp(() {
    manifest = _Manifest();
    serverVersion = ValueNotifier<String?>(null);
    postponed = null;
  });

  tearDown(() => prompter.dispose());

  testWidgets('a sign-in finds the waiting build and offers it', (
    tester,
  ) async {
    manifest.offered = '0.8.0';
    prompter = build();
    var notified = 0;
    prompter.addListener(() => notified += 1);

    prompter.start();
    await tester.pump();

    expect(notified, 1);
    expect(prompter.offer!.currentVersion, '0.7.9');
    expect(prompter.offer!.release.version, '0.8.0');
  });

  testWidgets('nothing is offered when the app is current', (tester) async {
    manifest.offered = '0.7.9';
    prompter = build();

    prompter.start();
    await tester.pump();

    expect(manifest.reads, 1);
    expect(prompter.offer, isNull);
  });

  testWidgets('a build that was shown is not offered twice in one run', (
    tester,
  ) async {
    manifest.offered = '0.8.0';
    prompter = build();
    prompter.start();
    await tester.pump();

    expect(prompter.takeOffer()!.release.version, '0.8.0');
    expect(prompter.offer, isNull);

    prompter.start(); // the next sign-in
    await tester.pump();

    expect(manifest.reads, 2);
    expect(prompter.offer, isNull);
  });

  testWidgets('"later" holds for that build only; the next one asks again', (
    tester,
  ) async {
    manifest.offered = '0.8.0';
    prompter = build();
    await prompter.postpone('0.8.0');

    prompter.start();
    await tester.pump();
    expect(prompter.offer, isNull);

    manifest.offered = '0.8.1';
    serverVersion.value = '0.8.1';
    await tester.pump();

    expect(prompter.offer!.release.version, '0.8.1');
  });

  testWidgets('a backend naming a new release triggers a look', (tester) async {
    prompter = build();
    prompter.start();
    await tester.pump();
    expect(manifest.reads, 1);

    // The remote update lands: the next response names the new release.
    manifest.offered = '0.8.0';
    serverVersion.value = '0.8.0';
    await tester.pump();

    expect(manifest.reads, 2);
    expect(prompter.offer!.release.version, '0.8.0');
  });

  testWidgets(
    'an old manifest right after the backend update is retried, not believed',
    (tester) async {
      // install.sh brings the stack up before it copies the new installers
      // in, so the first look can still see the previous build.
      prompter = build(
        retryDelays: const [Duration(seconds: 30), Duration(minutes: 1)],
      );
      prompter.start();
      await tester.pump();

      serverVersion.value = '0.8.0';
      await tester.pump();
      expect(manifest.reads, 2);
      expect(prompter.offer, isNull);

      await tester.pump(const Duration(seconds: 30));
      expect(manifest.reads, 3, reason: 'first retry');
      expect(prompter.offer, isNull);

      manifest.offered = '0.8.0'; // the installers are published now
      await tester.pump(const Duration(minutes: 1));

      expect(manifest.reads, 4);
      expect(prompter.offer!.release.version, '0.8.0');
    },
  );

  testWidgets('the retries stop once the budget is spent', (tester) async {
    prompter = build(retryDelays: const [Duration(seconds: 30)]);
    prompter.start();
    await tester.pump();
    serverVersion.value = '0.8.0'; // e.g. a shop whose bundle has no APK
    await tester.pump();

    await tester.pump(const Duration(seconds: 30));
    await tester.pump(const Duration(hours: 1));

    expect(manifest.reads, 3);
  });

  testWidgets('no retry when the backend is not ahead of this app', (
    tester,
  ) async {
    prompter = build(retryDelays: const [Duration(seconds: 30)]);
    prompter.start();
    await tester.pump();
    serverVersion.value = '0.7.9';
    await tester.pump();

    await tester.pump(const Duration(minutes: 5));

    expect(manifest.reads, 2);
  });

  testWidgets('a failed look is silence, not an error', (tester) async {
    prompter = AppUpdatePrompter(
      check: () async => throw StateError('offline'),
      serverVersion: serverVersion,
      loadPostponed: () async => null,
      savePostponed: (_) async {},
    );

    prompter.start();
    await tester.pump();

    expect(prompter.offer, isNull);
  });
}
