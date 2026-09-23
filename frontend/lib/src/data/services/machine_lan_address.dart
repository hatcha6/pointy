import 'dart:io' show InternetAddressType, NetworkInterface;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'lan_interfaces.dart';

/// Reads this machine's IPv4 addresses, each with the adapter that holds it.
/// Injectable so tests never touch the real network stack.
typedef MachineAddressReader = Future<List<LanAddressCandidate>> Function();

Future<List<LanAddressCandidate>> readMachineIpv4Addresses() async {
  // dart:io's NetworkInterface does not exist in a browser.
  if (kIsWeb) return const [];
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses)
        (interfaceName: interface.name, address: address.address),
  ];
}

/// [url] as another device on the shop network can open it.
///
/// A link or QR this app shows is built from the address it reaches the backend
/// on. Normally that is already the server's LAN address. On the server machine
/// itself it is loopback (`127.0.0.1`, `localhost`), which on any other device
/// means *that* device. App and server share the machine, so the machine's own
/// LAN address is the server's LAN address: swap it in, keeping the scheme,
/// port, path and fragment.
///
/// The backend cannot make this swap itself: inside Docker (and inside WSL on
/// Windows) it sees only its own private networks, never the shop's. Returns
/// [url] unchanged when it is not loopback or no LAN address is found.
Future<String> lanReachableUrl(
  String url, {
  MachineAddressReader readAddresses = readMachineIpv4Addresses,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !isLoopbackHost(uri.host)) {
    return url;
  }
  try {
    final lanHost = bestLanIpv4(await readAddresses());
    return lanHost == null ? url : uri.replace(host: lanHost).toString();
  } on Object {
    return url;
  }
}
