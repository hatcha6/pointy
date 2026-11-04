import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lan_interfaces.dart';
import 'onvif_ws_discovery.dart';

/// Multicasts an ONVIF WS-Discovery `Probe` and collects who answers.
///
/// One socket per LAN address as well as the wildcard, as the backend
/// discovery does: on a till with two adapters the wildcard's multicast leaves
/// by one of them only, and the cameras may be behind the other. The probe goes
/// out three times inside [window] because UDP drops datagrams and a device
/// answers each probe it hears; replies are folded by sender.
Future<List<OnvifAdvert>> discoverOnvifDevices({
  Duration window = const Duration(milliseconds: 1800),
}) async {
  final adverts = <String, OnvifAdvert>{};
  final sockets = <RawDatagramSocket>[];

  void handle(RawDatagramSocket socket) {
    final datagram = socket.receive();
    if (datagram == null) {
      return;
    }
    final advert = parseOnvifProbeMatch(
      utf8.decode(datagram.data, allowMalformed: true),
      senderHost: datagram.address.address,
    );
    if (advert != null) {
      adverts.putIfAbsent(advert.host, () => advert);
    }
  }

  final bindAddresses = <InternetAddress>[InternetAddress.anyIPv4];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final octets = ipv4Octets(address.address);
        if (octets != null && isUsableLanIpv4(octets)) {
          bindAddresses.add(address);
        }
      }
    }
  } on Object {
    // Enumeration failed — the wildcard still gets a shot.
  }

  for (final bindAddress in bindAddresses) {
    try {
      final socket = await RawDatagramSocket.bind(bindAddress, 0);
      socket.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            handle(socket);
          }
        },
        // A send the OS refuses (no route, an adapter that just went away)
        // arrives here a microtask later, not at `send`. Best-effort: a lost
        // probe is a miss, never a crash.
        onError: (Object _) {},
      );
      sockets.add(socket);
    } on Object {
      // An address we cannot bind (permissions, a transient adapter).
    }
  }
  if (sockets.isEmpty) {
    return const [];
  }

  final group = InternetAddress(wsDiscoveryMulticastAddress);
  final probes = [
    for (final type in onvifProbeTypes) utf8.encode(onvifProbeMessage(type)),
  ];
  void probe() {
    for (final socket in sockets) {
      for (final message in probes) {
        try {
          socket.send(message, group, wsDiscoveryPort);
        } on Object {
          // One failed send must not abort the others.
        }
      }
    }
  }

  probe();
  final resend = Timer.periodic(
    Duration(milliseconds: window.inMilliseconds ~/ 3),
    (_) => probe(),
  );
  await Future<void>.delayed(window);
  resend.cancel();
  for (final socket in sockets) {
    socket.close();
  }
  return adverts.values.toList(growable: false);
}
