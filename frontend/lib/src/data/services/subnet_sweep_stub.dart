/// Web cannot open raw TCP/UDP sockets, so there is no subnet sweep there;
/// discovery falls back to the same-origin default.
Future<List<String>> sweepSubnetForBackends({
  String? expectedInstallationId,
  int port = 8000,
  Duration perProbeTimeout = const Duration(milliseconds: 400),
  int concurrency = 32,
}) async {
  return const [];
}
