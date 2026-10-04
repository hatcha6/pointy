/// Web cannot open raw TCP/UDP sockets, so there is no subnet sweep there;
/// discovery falls back to the same-origin default.
Future<List<String>> sweepSubnetForBackends({
  String? expectedInstallationId,
  int port = 8000,
  Duration perProbeTimeout = const Duration(milliseconds: 400),
  Duration answerTimeout = const Duration(seconds: 3),
  int concurrency = 32,
}) async {
  return const [];
}
