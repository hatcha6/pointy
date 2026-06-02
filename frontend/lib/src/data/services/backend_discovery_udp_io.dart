import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<List<Uri>> discoverBackendApiBaseUrls({
  Duration timeout = const Duration(seconds: 2),
  int port = 47777,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final found = <String, Uri>{};
  final completer = Completer<List<Uri>>();
  Timer? timer;
  StreamSubscription<RawSocketEvent>? subscription;

  void finish() {
    if (completer.isCompleted) {
      return;
    }
    timer?.cancel();
    subscription?.cancel();
    socket.close();
    completer.complete(found.values.toList(growable: false));
  }

  socket.broadcastEnabled = true;
  subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final datagram = socket.receive();
    if (datagram == null) {
      return;
    }
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) {
        return;
      }
      if (decoded['service']?.toString() != 'pointy-backend') {
        return;
      }
      final rawApiBaseUrl = decoded['api_base_url']?.toString() ?? '';
      final uri = Uri.tryParse(rawApiBaseUrl);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return;
      }
      found[uri.toString()] = uri;
      finish();
    } on FormatException {
      return;
    }
  });

  socket.send(
    utf8.encode('POINTY_DISCOVERY_V1'),
    InternetAddress('255.255.255.255'),
    port,
  );
  timer = Timer(timeout, finish);
  return completer.future;
}
