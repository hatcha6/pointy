import 'dart:io';

/// Whether something accepts a TCP connection at [url]'s host and port.
///
/// It says nothing about what: the shop's server, the port forward in front of
/// it, or another device holding the address. Discovery asks it one thing
/// only — whether a candidate that has not answered yet is worth waiting for.
/// A server on the shop's network completes the handshake in milliseconds
/// however busy it is, because the kernel answers it, not the backend; an
/// address on some other network never does.
Future<bool> probeServerPresence(
  Uri url, {
  Duration timeout = const Duration(milliseconds: 900),
}) async {
  if (url.host.isEmpty) {
    return false;
  }
  try {
    final socket = await Socket.connect(url.host, url.port, timeout: timeout);
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}
