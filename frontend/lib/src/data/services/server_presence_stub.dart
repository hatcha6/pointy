/// Web cannot open raw sockets, so presence is never known there and every
/// discovery probe keeps its short deadline.
Future<bool> probeServerPresence(
  Uri url, {
  Duration timeout = const Duration(milliseconds: 900),
}) async {
  return false;
}
