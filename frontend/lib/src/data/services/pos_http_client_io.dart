import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'lan_interfaces.dart';

/// How long a connection to an address on the shop's own network may take to
/// be accepted before the request gives up on it.
///
/// A server on the LAN accepts in milliseconds even when it is too busy to
/// answer quickly — the kernel completes the handshake, not the backend. A
/// connection still pending after this long is to an address that is not
/// there: most often a device carried out of the shop, whose saved LAN address
/// now leads into another network's router or a mobile carrier and is dropped
/// without a word. Left to the OS that wait runs past the request deadline, so
/// every request the app sent sat out a full minute and then failed in the one
/// way that is never repeated on the relay. Bounded, it fails as an
/// unreachable address does, and the relay takes it.
///
/// Long enough for one lost handshake packet to be sent again: Windows waits
/// three seconds before its first retry.
const lanConnectTimeout = Duration(seconds: 5);

http.Client createPlatformHttpClient() => LanAwareHttpClient();

/// Sends a request to the shop's own network ([isLocalNetworkHost]) through a
/// client that gives up on a connection after [lanConnectTimeout], and
/// anything else — the relay, the internet — through one that sets no such
/// bound: a phone on a poor mobile link can take that long to reach the relay
/// and still get there.
class LanAwareHttpClient extends http.BaseClient {
  LanAwareHttpClient({Duration connectTimeout = lanConnectTimeout})
    : this.withClients(
        lan: IOClient(HttpClient()..connectionTimeout = connectTimeout),
        internet: IOClient(),
      );

  LanAwareHttpClient.withClients({
    required http.Client lan,
    required http.Client internet,
  }) : _lan = lan,
       _internet = internet;

  final http.Client _lan;
  final http.Client _internet;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final client = isLocalNetworkHost(request.url.host) ? _lan : _internet;
    return client.send(request);
  }

  @override
  void close() {
    _lan.close();
    _internet.close();
  }
}
