/// The build this client was compiled from.
///
/// Injected at build time with `--dart-define=POINTY_VERSION=<tag>`; empty for
/// local/unbuilt runs, in which case nothing claims a version rather than
/// claiming a wrong one. Every telemetry event and every API request carries
/// it, because without it a field regression cannot be tied to a release — in
/// the first client's dump all 4M frontend events had an empty app_version, so
/// there was no way to tell which build any of them came from.
const String kAppVersion = String.fromEnvironment('POINTY_VERSION');

/// When this process began, as close to the top of `main` as Dart can get.
///
/// Startup time could not be measured at all from the last field export:
/// `app.started` carried an empty payload, so the one number that says whether
/// a till is slow to become usable in the morning simply did not exist.
final Stopwatch kProcessUptime = Stopwatch()..start();

/// The version this build reports, and how it knows.
///
/// `POINTY_VERSION` is injected by the release workflows and is the answer
/// whenever it is there. When it is not — a locally built binary, or one from
/// before the define existed — falling back to the bundled package version is
/// far better than reporting nothing: a blank column is indistinguishable from
/// "we forgot to instrument this", which is exactly the confusion that made a
/// whole fleet's builds unidentifiable in the field.
class ResolvedAppVersion {
  const ResolvedAppVersion(this.value, this.source);

  final String value;

  /// `define` (the release workflows) or `package` (the bundle's own version).
  final String source;

  static const ResolvedAppVersion unknown = ResolvedAppVersion('', 'unknown');

  bool get isKnown => value.isNotEmpty;
}
