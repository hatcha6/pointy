import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/linux_self_update.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pointy-linux-update-test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('findLinuxBundleRoot', () {
    test('accepts a flat bundle layout', () {
      File('${root.path}/pointy_frontend').writeAsStringSync('');
      expect(findLinuxBundleRoot(root, 'pointy_frontend')?.path, root.path);
    });

    test('finds the CI top-level directory layout', () {
      final inner = Directory('${root.path}/pointy-1.5.0-linux-x64')
        ..createSync();
      File('${inner.path}/pointy_frontend').writeAsStringSync('');
      expect(findLinuxBundleRoot(root, 'pointy_frontend')?.path, inner.path);
    });

    test('returns null when the executable is missing', () {
      Directory('${root.path}/docs').createSync();
      expect(findLinuxBundleRoot(root, 'pointy_frontend'), isNull);
    });
  });

  group(
    'handoff script',
    skip: Platform.isWindows ? 'POSIX-only handoff script' : false,
    () {
      // Writes a fake app bundle whose "executable" is a shell script that
      // stamps a marker file, so the test can observe which build relaunched.
      Directory fakeBundle(String path, String stamp) {
        final dir = Directory(path)..createSync(recursive: true);
        File('${dir.path}/version.txt').writeAsStringSync(stamp);
        final exe = File('${dir.path}/pointy_frontend')
          ..writeAsStringSync(
            '#!/bin/sh\necho "$stamp" > "\$(dirname "\$0")/relaunched.txt"\n',
          );
        Process.runSync('chmod', ['+x', exe.path]);
        return dir;
      }

      Future<int> runHandoff({
        required String src,
        required String dst,
        required String staging,
      }) async {
        final script = File('${root.path}/handoff.sh')
          ..writeAsStringSync(linuxUpdateHandoffScript);
        // A short-lived stand-in for the running app: the script must wait for
        // it to exit before swapping.
        final app = await Process.start('sleep', ['1']);
        final handoff = await Process.start('/bin/sh', [
          script.path,
          '${app.pid}',
          src,
          dst,
          staging,
          'pointy_frontend',
        ]);
        return handoff.exitCode.timeout(const Duration(seconds: 30));
      }

      test(
        'waits for exit, swaps the bundle, cleans up and relaunches',
        () async {
          final dst = fakeBundle('${root.path}/app', 'old');
          final staging = Directory('${root.path}/.staging')..createSync();
          final src = fakeBundle(
            '${staging.path}/pointy-2.0.0-linux-x64',
            'new',
          );

          expect(
            await runHandoff(
              src: src.path,
              dst: dst.path,
              staging: staging.path,
            ),
            0,
          );

          expect(File('${dst.path}/version.txt').readAsStringSync(), 'new');
          expect(
            File('${dst.path}/relaunched.txt').readAsStringSync().trim(),
            'new',
          );
          expect(Directory('${dst.path}.old').existsSync(), isFalse);
          expect(staging.existsSync(), isFalse);
        },
      );

      test(
        'restores the old bundle when the new one cannot be moved in',
        () async {
          final dst = fakeBundle('${root.path}/app', 'old');
          final staging = Directory('${root.path}/.staging')..createSync();

          await runHandoff(
            src: '${staging.path}/does-not-exist',
            dst: dst.path,
            staging: staging.path,
          );

          expect(File('${dst.path}/version.txt').readAsStringSync(), 'old');
          expect(
            File('${dst.path}/relaunched.txt').readAsStringSync().trim(),
            'old',
          );
        },
      );
    },
  );
}
