import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Boots [SharedPreferences] so a corrupt on-disk store can never stop the app
/// from starting.
///
/// ## The failure this guards against
///
/// On desktop, `shared_preferences` persists everything to a single
/// `shared_preferences.json` file in the app-support directory. Its Windows
/// backend rewrites that file in place with a **non-atomic**
/// `writeAsStringSync` — it truncates the existing file and streams the new
/// contents over it, with no temp-file-and-rename and no fsync. If the machine
/// loses power mid-write — a routine event on the POS hardware we ship to — the
/// file is left half-written and is no longer valid JSON.
///
/// The read path makes that fatal: `shared_preferences_windows` calls
/// `json.decode` on the file contents with no `try/catch`, so a truncated file
/// throws `FormatException` straight out of `SharedPreferences.getInstance()`.
/// Because every local store in the app (connection profile, auth session, POS
/// and purchase draft snapshots, theme, device settings…) funnels through that
/// one call, a single corrupt file takes the whole frontend down: it can't find
/// its backend, can't restore state, and effectively won't start.
///
/// ## What this does
///
/// [ensureHealthy] warms the cache once. If the load throws, it moves the
/// unreadable file aside (quarantines it for later diagnosis) and retries, so
/// the process comes up with a clean, empty store instead of crashing. The lost
/// data is only local convenience state — the backend is re-discovered on the
/// LAN automatically and drafts are best-effort crash-recovery snapshots — so a
/// working app with defaults beats a dead one.
class ResilientPreferences {
  const ResilientPreferences._();

  /// The `shared_preferences` backend writes `<name>.json`; the default name is
  /// `shared_preferences`, matching the file we see corrupted in AppData.
  static const String storeFileName = 'shared_preferences.json';

  /// Suffix marking a quarantined (previously corrupt) store.
  static const String _quarantineMarker = '.corrupt-';

  /// Keep this many quarantined files for diagnosis; older ones are pruned so a
  /// machine that corrupts on every boot can't accumulate them without bound.
  static const int _quarantineKeep = 3;

  /// Resolves the directory that holds [storeFileName]. On Windows this is the
  /// same `getApplicationSupportPath()` that `shared_preferences_windows` uses,
  /// so we operate on the exact file it reads. Overridable for tests.
  @visibleForTesting
  static Future<Directory> Function() supportDirectoryResolver =
      getApplicationSupportDirectory;

  /// Attempts to load the store once. Overridable for tests. In production this
  /// is `SharedPreferences.getInstance()`, whose legacy implementation clears
  /// its cached completer on error, so a later call genuinely re-reads the file.
  @visibleForTesting
  static Future<void> Function() storeWarmup = _defaultWarmup;

  static Future<void> _defaultWarmup() async {
    await SharedPreferences.getInstance();
  }

  /// Ensures `SharedPreferences.getInstance()` will succeed for the rest of the
  /// process. Call this from `main()` before `runApp`, after
  /// `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// Safe to call more than once and safe on every platform: web and mobile
  /// don't use the JSON file store, so the recovery branch is simply never
  /// taken there. This method never throws.
  static Future<void> ensureHealthy() async {
    try {
      await storeWarmup();
      return;
    } catch (error, stackTrace) {
      debugPrint(
        'SharedPreferences failed to load, attempting recovery: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }

    final bool quarantined = await _quarantineCorruptStore();
    if (!quarantined) {
      // Nothing to reset — either this isn't the file-backed desktop store, or
      // the support directory is unavailable. Don't mask the problem by
      // pretending we fixed it; leave lazy callers to fail as they would have.
      debugPrint('SharedPreferences recovery found no store file to reset.');
      return;
    }

    try {
      await storeWarmup();
      debugPrint('SharedPreferences recovered with a fresh store.');
    } catch (error) {
      // A second failure is not power-loss corruption (we just deleted the file
      // that would decode-fail); surface it in logs but still don't crash boot.
      debugPrint('SharedPreferences still unavailable after reset: $error');
    }
  }

  /// Moves an unreadable store file aside so the next load starts empty.
  /// Returns true when a file was found and quarantined.
  static Future<bool> _quarantineCorruptStore() async {
    // Only the file-backed desktop implementations can be repaired this way.
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return false;
    }
    final Directory supportDir;
    try {
      supportDir = await supportDirectoryResolver();
    } catch (error) {
      debugPrint('Could not resolve application support directory: $error');
      return false;
    }
    return quarantineCorruptStore(supportDir);
  }

  /// Renames the corrupt [storeFileName] inside [supportDir] to a timestamped
  /// `.corrupt-*` sibling (or deletes it if the rename fails), then prunes old
  /// quarantine files. Returns true when a store file existed and was cleared.
  ///
  /// Exposed for testing; production callers use [ensureHealthy].
  @visibleForTesting
  static Future<bool> quarantineCorruptStore(
    Directory supportDir, {
    DateTime? now,
  }) async {
    final File file = File(_join(supportDir.path, storeFileName));
    if (!file.existsSync()) {
      return false;
    }

    final int stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final String quarantinePath = '${file.path}$_quarantineMarker$stamp';
    try {
      // Rename is itself atomic and keeps a copy for post-mortem inspection.
      file.renameSync(quarantinePath);
      debugPrint('Quarantined corrupt preferences to $quarantinePath');
    } catch (renameError) {
      debugPrint(
        'Could not rename corrupt preferences, deleting instead: $renameError',
      );
      try {
        file.deleteSync();
      } catch (deleteError) {
        debugPrint('Could not delete corrupt preferences: $deleteError');
        return false;
      }
    }

    _pruneOldQuarantines(supportDir);
    return true;
  }

  static void _pruneOldQuarantines(Directory supportDir) {
    try {
      const String prefix = '$storeFileName$_quarantineMarker';
      final List<File> quarantines =
          supportDir
              .listSync()
              .whereType<File>()
              .where((f) => _basename(f.path).startsWith(prefix))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (quarantines.length <= _quarantineKeep) {
        return;
      }
      for (final File stale in quarantines.take(
        quarantines.length - _quarantineKeep,
      )) {
        try {
          stale.deleteSync();
        } catch (_) {
          // Best effort; a leftover file is harmless.
        }
      }
    } catch (error) {
      debugPrint('Could not prune old quarantined preferences: $error');
    }
  }

  static String _join(String dir, String name) {
    final String sep = Platform.pathSeparator;
    return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
  }

  static String _basename(String path) {
    final int index = path.lastIndexOf(Platform.pathSeparator);
    return index == -1 ? path : path.substring(index + 1);
  }
}
