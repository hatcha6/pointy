import 'recorder_discovery.dart';

/// Web cannot open raw sockets or read cross-origin responses, so there is no
/// LAN sweep there — the address has to be typed.
Future<List<DiscoveredRecorder>> discoverRecordersPlatform({
  Duration perProbeTimeout = const Duration(milliseconds: 400),
  int concurrency = 64,
}) async {
  return const [];
}
