import 'dart:async';

/// Web has no UDP sockets; discovery there relies on the same-origin default.
Future<List<Uri>> discoverBackendApiBaseUrls({
  Duration timeout = const Duration(seconds: 2),
  int port = 47777,
  Duration resendInterval = const Duration(milliseconds: 300),
}) async {
  return const [];
}
