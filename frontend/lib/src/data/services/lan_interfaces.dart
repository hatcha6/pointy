/// Pure IPv4 / LAN helpers shared by backend discovery (UDP broadcast + subnet
/// sweep) and the client self-update service.
///
/// Deliberately free of `dart:io` so it compiles on web and is trivially unit
/// testable: every function operates on already-parsed octets or plain strings.
/// The socket-bound callers (which do import `dart:io`) enumerate
/// `NetworkInterface`s and feed the raw addresses through here.
library;

/// Rank returned for addresses that are not in a well-known private IPv4 range.
const int unrankedPrivateIpv4 = 3;

/// Parses a dotted IPv4 string (`"192.168.1.5"`) into its four octets, or null
/// when the value is not a plain IPv4 address (IPv6, hostnames, garbage).
List<int>? ipv4Octets(String address) {
  final parts = address.split('.');
  if (parts.length != 4) {
    return null;
  }
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) {
      return null;
    }
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) {
      return null;
    }
    octets.add(value);
  }
  return octets;
}

/// Ranks the private IPv4 ranges shop routers actually hand out so a VPN or
/// virtual adapter (Hyper-V/WSL/docker) never wins over the real LAN interface.
/// Lower is better. Mirrors the ordering previously inlined in
/// `client_update_service.dart`.
int privateIpv4Rank(List<int> raw) {
  if (raw.length != 4) return unrankedPrivateIpv4;
  if (raw[0] == 192 && raw[1] == 168) return 0;
  if (raw[0] == 10) return 1;
  if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return 2;
  return unrankedPrivateIpv4;
}

/// True for 127.0.0.0/8 (loopback) or 169.254.0.0/16 (link-local). Those are
/// never the LAN interface we want to broadcast on or sweep.
bool isLoopbackOrLinkLocalIpv4(List<int> raw) {
  if (raw.length != 4) return false;
  if (raw[0] == 127) return true;
  if (raw[0] == 169 && raw[1] == 254) return true;
  return false;
}

/// True for an address worth probing on: a private, non-loopback,
/// non-link-local IPv4.
bool isUsableLanIpv4(List<int> raw) {
  if (isLoopbackOrLinkLocalIpv4(raw)) return false;
  return privateIpv4Rank(raw) < unrankedPrivateIpv4;
}

/// The /24 directed broadcast address for [raw] (`"192.168.1.255"`).
///
/// Dart's [NetworkInterface] does not expose the netmask, so we assume the
/// overwhelmingly common /24 LAN. Directed broadcast reaches subnets whose AP or
/// firewall drops the `255.255.255.255` limited broadcast.
String directedBroadcastIpv4(List<int> raw) {
  return '${raw[0]}.${raw[1]}.${raw[2]}.255';
}

/// Every unicast host address in the /24 containing [raw] (`.1`–`.254`),
/// assuming a /24. Used by the subnet sweep. Order starts near [raw]'s own host
/// octet so the server — usually adjacent (router/first static host) — is found
/// early, then fans outward.
List<String> subnetHostsIpv4(List<int> raw) {
  final prefix = '${raw[0]}.${raw[1]}.${raw[2]}';
  final self = raw[3];
  final order = <int>[];
  for (var distance = 0; distance <= 254; distance++) {
    final lower = self - distance;
    final upper = self + distance;
    if (distance == 0) {
      if (self >= 1 && self <= 254) order.add(self);
      continue;
    }
    if (lower >= 1 && lower <= 254) order.add(lower);
    if (upper >= 1 && upper <= 254) order.add(upper);
  }
  return [for (final host in order) '$prefix.$host'];
}

/// Filters and ranks a set of interface address strings to the usable LAN IPv4
/// octets, best-first (real LAN before VPN/virtual). Non-IPv4 and
/// loopback/link-local addresses are dropped.
List<List<int>> preferredLanIpv4Octets(Iterable<String> addresses) {
  final ranked = <(int, List<int>)>[];
  final seen = <String>{};
  for (final address in addresses) {
    final octets = ipv4Octets(address);
    if (octets == null || !isUsableLanIpv4(octets)) {
      continue;
    }
    if (!seen.add(address)) {
      continue;
    }
    ranked.add((privateIpv4Rank(octets), octets));
  }
  ranked.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final entry in ranked) entry.$2];
}
