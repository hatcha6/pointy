import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/resilient_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('resilient_prefs_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String join(String name) => '${tempDir.path}${Platform.pathSeparator}$name';

  File storeFile() => File(join(ResilientPreferences.storeFileName));

  List<File> quarantineFiles() => tempDir
      .listSync()
      .whereType<File>()
      .where(
        (f) =>
            f.path.contains('${ResilientPreferences.storeFileName}.corrupt-'),
      )
      .toList();

  group('quarantineCorruptStore', () {
    test('moves a corrupt store aside and leaves no live store file', () async {
      const corruptBytes = '{"flutter.key": "val'; // truncated JSON
      storeFile().writeAsStringSync(corruptBytes);

      final moved = await ResilientPreferences.quarantineCorruptStore(tempDir);

      expect(moved, isTrue);
      expect(
        storeFile().existsSync(),
        isFalse,
        reason:
            'the unreadable store must be gone so a fresh read starts empty',
      );
      final quarantined = quarantineFiles();
      expect(quarantined, hasLength(1));
      expect(
        quarantined.single.readAsStringSync(),
        corruptBytes,
        reason: 'the corrupt bytes are preserved for diagnosis',
      );
    });

    test('returns false when there is no store file to reset', () async {
      final moved = await ResilientPreferences.quarantineCorruptStore(tempDir);
      expect(moved, isFalse);
      expect(quarantineFiles(), isEmpty);
    });

    test(
      'prunes old quarantine files, keeping only the most recent few',
      () async {
        // Seed more historical quarantines than we retain.
        for (var i = 0; i < 6; i++) {
          File(
            join('${ResilientPreferences.storeFileName}.corrupt-$i'),
          ).writeAsStringSync('old');
        }
        storeFile().writeAsStringSync('garbage');

        await ResilientPreferences.quarantineCorruptStore(
          tempDir,
          now: DateTime.fromMillisecondsSinceEpoch(9999999999999),
        );

        // The freshly quarantined file plus the retained history must stay
        // bounded no matter how many outages a machine has suffered.
        expect(quarantineFiles(), hasLength(3));
        expect(storeFile().existsSync(), isFalse);
      },
    );
  });

  group('ensureHealthy', () {
    test('recovers and retries when the first load throws', () async {
      storeFile().writeAsStringSync('not json');
      ResilientPreferences.supportDirectoryResolver = () async => tempDir;

      var calls = 0;
      ResilientPreferences.storeWarmup = () async {
        calls++;
        // Mirror the real backend: it decode-throws while the corrupt file is
        // present, and succeeds once it has been quarantined away.
        if (storeFile().existsSync()) {
          throw const FormatException('Unexpected end of input');
        }
      };

      await ResilientPreferences.ensureHealthy();

      expect(calls, 2, reason: 'load is attempted, fails, then retried once');
      expect(storeFile().existsSync(), isFalse);
      expect(quarantineFiles(), hasLength(1));
    });

    test('does not throw or quarantine when the first load succeeds', () async {
      storeFile().writeAsStringSync('{"flutter.ok": true}');
      ResilientPreferences.supportDirectoryResolver = () async => tempDir;

      var calls = 0;
      ResilientPreferences.storeWarmup = () async => calls++;

      await ResilientPreferences.ensureHealthy();

      expect(calls, 1);
      expect(
        storeFile().existsSync(),
        isTrue,
        reason: 'a healthy store is left untouched',
      );
      expect(quarantineFiles(), isEmpty);
    });
  });
}
