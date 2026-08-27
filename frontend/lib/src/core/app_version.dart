/// The build this client was compiled from.
///
/// Injected at build time with `--dart-define=POINTY_VERSION=<tag>`; empty for
/// local/unbuilt runs, in which case nothing claims a version rather than
/// claiming a wrong one. Every telemetry event and every API request carries
/// it, because without it a field regression cannot be tied to a release — in
/// the first client's dump all 4M frontend events had an empty app_version, so
/// there was no way to tell which build any of them came from.
const String kAppVersion = String.fromEnvironment('POINTY_VERSION');
