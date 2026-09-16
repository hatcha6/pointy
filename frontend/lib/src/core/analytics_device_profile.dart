import 'dart:ui';

import 'package:package_info_plus/package_info_plus.dart';

import 'analytics_host_facts_stub.dart'
    if (dart.library.io) 'analytics_host_facts_io.dart';
import 'app_version.dart';

/// What this machine is, gathered once per launch.
///
/// Kept out of [AnalyticsEngine] and handed to it, for two reasons. The engine
/// runs on the web, where `dart:io` does not exist and importing it would break
/// the build outright; and every one of these lookups is a platform channel or
/// a file read, which a unit test should be able to answer for itself rather
/// than have to own a window and a bundle to run.
class AnalyticsDeviceProfile {
  const AnalyticsDeviceProfile({
    this.appVersion = '',
    this.versionSource = 'unknown',
    this.attributes = const {},
    this.metrics = const {},
  });

  /// The version to stamp on every event this launch records.
  final String appVersion;

  /// Where [appVersion] came from: `define`, `package`, or `unknown`.
  ///
  /// Worth recording in its own right. A fleet reporting `package` is a fleet
  /// whose release pipeline is not injecting the define, which is a different
  /// problem from a fleet reporting nothing, and from an export the two look
  /// identical.
  final String versionSource;

  /// Facts for the launch event's payload.
  final Map<String, Object?> attributes;
  final Map<String, num> metrics;

  static const AnalyticsDeviceProfile unknown = AnalyticsDeviceProfile();
}

/// The width the `app_version` column will accept.
const int _maxVersionLength = 40;

AnalyticsDeviceProfile? _override;

/// Answers [resolveAnalyticsDeviceProfile] with [profile] instead of reading
/// the machine, mirroring `AppKeyValueStore.debugOverride`.
///
/// The bundle lookup behind the version fallback is real file I/O, and under
/// `flutter test` real I/O never completes: the fake clock does not pump the
/// platform's event loop. A widget test that builds the app would otherwise sit
/// on a lookup it has no use for until the engine's own deadline, and fail on
/// the timer that deadline leaves armed. Installed globally for the suite by
/// `test/flutter_test_config.dart`, for the same reason the key/value store is.
void debugOverrideAnalyticsDeviceProfile(AnalyticsDeviceProfile profile) {
  _override = profile;
}

void debugResetAnalyticsDeviceProfile() {
  _override = null;
}

/// Reads the machine, for the one event that describes a launch.
///
/// Every lookup is individually guarded: a launch must not be held up, and must
/// certainly not fail, because telemetry wanted to know the screen size.
Future<AnalyticsDeviceProfile> resolveAnalyticsDeviceProfile() async {
  final override = _override;
  if (override != null) {
    return override;
  }
  final version = await _resolveAppVersion();
  final host = await readHostFacts();
  final attributes = <String, Object?>{
    ...host.attributes,
    ..._displayAttributes(),
  };
  final metrics = <String, num>{...host.metrics, ..._displayMetrics()};
  return AnalyticsDeviceProfile(
    appVersion: version.value,
    versionSource: version.source,
    attributes: attributes,
    metrics: metrics,
  );
}

/// The version, and how it was found.
///
/// `POINTY_VERSION` is what the release workflows inject and is authoritative
/// whenever it is there. The fallback matters more than it looks: the last
/// field export had an empty `app_version` on all 4M frontend rows, so no
/// finding in it could be tied to a build, and the tills were in fact running
/// something older than the define itself. A binary that predates the define
/// still knows its own bundled version, and saying so is far better than
/// leaving the column blank — blank is indistinguishable from "never
/// instrumented".
Future<ResolvedAppVersion> _resolveAppVersion() async {
  final defined = kAppVersion.trim();
  if (defined.isNotEmpty) {
    return ResolvedAppVersion(_truncate(defined), 'define');
  }
  try {
    final info = await PackageInfo.fromPlatform();
    final packaged = info.version.trim();
    if (packaged.isEmpty) {
      return ResolvedAppVersion.unknown;
    }
    final build = info.buildNumber.trim();
    return ResolvedAppVersion(
      _truncate(build.isEmpty ? packaged : '$packaged+$build'),
      'package',
    );
  } catch (_) {
    // A platform channel that never answers, or a bundle with no manifest.
    return ResolvedAppVersion.unknown;
  }
}

Map<String, Object?> _displayAttributes() {
  try {
    return {'ui_locale': PlatformDispatcher.instance.locale.toLanguageTag()};
  } catch (_) {
    return const {};
  }
}

/// The screen, in the only terms that are comparable between machines.
///
/// Both the window and the display are recorded because on a till they are
/// usually the same thing and when they are not, that is the finding: a POS run
/// in a half-height window on a big monitor is a layout complaint waiting to
/// happen, and the export had no way to see it. Zero is never reported — before
/// the first frame the view can legitimately have no size yet, and a fabricated
/// 0x0 would pollute every average taken over the fleet.
Map<String, num> _displayMetrics() {
  try {
    final view = PlatformDispatcher.instance.implicitView;
    if (view == null) {
      return const {};
    }
    final ratio = view.devicePixelRatio;
    final window = view.physicalSize;
    final display = view.display.size;
    return {
      if (ratio > 0) 'device_pixel_ratio': ratio,
      if (window.width > 0) 'window_width_px': window.width.round(),
      if (window.height > 0) 'window_height_px': window.height.round(),
      if (display.width > 0) 'screen_width_px': display.width.round(),
      if (display.height > 0) 'screen_height_px': display.height.round(),
    };
  } catch (_) {
    return const {};
  }
}

String _truncate(String value) {
  if (value.length <= _maxVersionLength) {
    return value;
  }
  return value.substring(0, _maxVersionLength);
}
