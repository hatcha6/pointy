import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lan_interfaces.dart';

/// Discovers Pointy backends on the LAN by UDP broadcast.
///
/// Robustness (vs. the naive "one datagram to 255.255.255.255") comes from
/// three things, because UDP is lossy and shop networks are hostile to
/// broadcast:
///   * **Per-interface sockets.** Multi-homed hosts (Wi-Fi + Ethernet, VPN,
///     Hyper-V/WSL/docker adapters) would otherwise egress the probe on the
///     wrong NIC. We bind one socket per usable LAN address plus a catch-all.
///   * **Dual broadcast.** Each socket probes both the limited broadcast
///     (255.255.255.255) and the /24 directed broadcast (x.y.z.255); APs and
///     Windows firewall profiles frequently drop one but not the other.
///   * **Resend cadence.** We re-broadcast every [resendInterval] until a valid
///     reply arrives or [timeout] elapses, so a single dropped frame is not a
///     total miss.
///
/// Returns as soon as the first valid `pointy-backend` reply is seen. The caller
/// still HTTP-probes the returned URL (confirming reachability and shop
/// identity), so a stray/spoofed datagram cannot by itself win a connection.
Future<List<Uri>> discoverBackendApiBaseUrls({
  Duration timeout = const Duration(seconds: 2),
  int port = 47777,
  Duration resendInterval = const Duration(milliseconds: 300),
}) async {
  final found = <String, Uri>{};
  final completer = Completer<List<Uri>>();
  final targets = <_BroadcastTarget>[];
  Timer? deadline;
  Timer? resend;

  void cleanup() {
    deadline?.cancel();
    resend?.cancel();
    for (final target in targets) {
      target.socket.close();
    }
  }

  void finish() {
    if (completer.isCompleted) {
      return;
    }
    cleanup();
    completer.complete(found.values.toList(growable: false));
  }

  void handle(RawDatagramSocket socket) {
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
      final uri = Uri.tryParse(decoded['api_base_url']?.toString() ?? '');
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return;
      }
      found[uri.toString()] = uri;
      // First valid backend is enough — resolve immediately for a fast path.
      finish();
    } on FormatException {
      return;
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
        if (octets == null || !isUsableLanIpv4(octets)) {
          continue;
        }
        bindAddresses.add(address);
      }
    }
  } on Object {
    // Enumeration failed — the anyIPv4 catch-all still gets a shot.
  }

  final probe = utf8.encode('POINTY_DISCOVERY_V1');
  final limitedBroadcast = InternetAddress('255.255.255.255');

  for (final bindAddress in bindAddresses) {
    try {
      final socket = await RawDatagramSocket.bind(bindAddress, 0);
      socket.broadcastEnabled = true;
      socket.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            handle(socket);
          }
        },
        // A datagram the OS refuses to send (no route: Wi-Fi off, an adapter
        // that just went away) is reported here, a microtask after `send`
        // returned, so the try around `send` never sees it. Unheard, it
        // became an uncaught "Send failed (Network is unreachable)" logged as
        // a critical error on every sweep (Android till, 2026-09-24). The
        // sweep is best-effort by design: a lost probe is just a miss.
        onError: (Object _) {},
      );
      final destinations = <InternetAddress>[limitedBroadcast];
      final octets = ipv4Octets(bindAddress.address);
      if (octets != null && isUsableLanIpv4(octets)) {
        final directed = InternetAddress.tryParse(
          directedBroadcastIpv4(octets),
        );
        if (directed != null) {
          destinations.add(directed);
        }
      }
      targets.add(_BroadcastTarget(socket, destinations));
    } on Object {
      // Skip interfaces we cannot bind (permissions, transient adapters).
    }
  }

  if (targets.isEmpty) {
    return const [];
  }

  void broadcast() {
    for (final target in targets) {
      for (final destination in target.destinations) {
        try {
          target.socket.send(probe, destination, port);
        } on Object {
          // A single failed send must not abort the sweep.
        }
      }
    }
  }

  broadcast();
  resend = Timer.periodic(resendInterval, (_) => broadcast());
  deadline = Timer(timeout, finish);
  return completer.future;
}

class _BroadcastTarget {
  _BroadcastTarget(this.socket, this.destinations);

  final RawDatagramSocket socket;
  final List<InternetAddress> destinations;
}
