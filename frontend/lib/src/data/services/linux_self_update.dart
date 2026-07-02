import 'dart:io';

/// Linux self-update: applies a downloaded portable `.tar.gz` client build.
///
/// Linux has no installer binary to hand off to (unlike Windows/Android), so
/// the app replaces its own bundle directory: extract the archive next to the
/// install dir (same filesystem, so renames are atomic), then spawn a detached
/// handoff script that waits for the app to exit, swaps the old bundle for the
/// new one (with rollback if the swap fails), and relaunches the app. Renaming
/// directories never writes into a running binary, so there is no ETXTBSY —
/// the swap just needs the install dir's *parent* to be writable, which holds
/// for the normal "extracted into the operator's home dir" install.
///
/// The handoff script. Args: `sh <script> <pid> <src> <dst> <staging> <exe>`.
const String linuxUpdateHandoffScript = r'''
#!/bin/sh
# Pointy Linux self-update handoff. Spawned detached by the running app just
# before it exits; see linux_self_update.dart.
pid=$1; src=$2; dst=$3; staging=$4; exe=$5
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i+1)); [ "$i" -ge 300 ] && exit 1
  sleep 1
done
cd /
rm -rf "$dst.old"
if mv "$dst" "$dst.old"; then
  if mv "$src" "$dst"; then
    rm -rf "$dst.old"
  else
    mv "$dst.old" "$dst"
  fi
fi
rm -rf "$staging"
rm -f "$0"
exec "$dst/$exe"
''';

/// The extracted bundle root: the directory holding [executableName]. The CI
/// tarball wraps the bundle in one `pointy-<version>-linux-x64/` top-level
/// directory, but accept a flat layout too. Returns null when neither matches.
Directory? findLinuxBundleRoot(Directory extracted, String executableName) {
  if (File('${extracted.path}/$executableName').existsSync()) {
    return extracted;
  }
  for (final entry in extracted.listSync()) {
    if (entry is Directory &&
        File('${entry.path}/$executableName').existsSync()) {
      return entry;
    }
  }
  return null;
}

/// Extracts [archivePath], stages the handoff script, spawns it detached and
/// exits the app. On success this never returns; throws (before exiting) when
/// the update cannot be applied — unwritable install location, bad archive.
Future<void> installLinuxUpdate(String archivePath) async {
  final executable = File(Platform.resolvedExecutable);
  final executableName = executable.uri.pathSegments.last;
  final installDir = executable.parent;
  final parent = installDir.parent;

  // The swap renames the install dir itself, so its parent must be writable.
  try {
    final probe = File('${parent.path}/.pointy-update-probe-$pid')
      ..writeAsStringSync('');
    probe.deleteSync();
  } on FileSystemException {
    throw Exception(
      'cannot self-update: ${parent.path} is not writable — '
      'update from the LAN download page instead',
    );
  }

  final staging = Directory('${parent.path}/.pointy-update-$pid')
    ..createSync(recursive: true);
  try {
    final tar = await Process.run('tar', [
      '-xzf',
      archivePath,
      '-C',
      staging.path,
    ]);
    if (tar.exitCode != 0) {
      throw Exception('could not extract the update archive: ${tar.stderr}');
    }
    final bundleRoot = findLinuxBundleRoot(staging, executableName);
    if (bundleRoot == null) {
      throw Exception('update archive does not contain $executableName');
    }

    final script = File(
      '${Directory.systemTemp.path}/pointy-self-update-$pid.sh',
    )..writeAsStringSync(linuxUpdateHandoffScript);
    await Process.start('/bin/sh', [
      script.path,
      '$pid',
      bundleRoot.path,
      installDir.path,
      staging.path,
      executableName,
    ], mode: ProcessStartMode.detached);
  } catch (_) {
    staging.deleteSync(recursive: true);
    rethrow;
  }
  exit(0);
}
