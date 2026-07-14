import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/lan_interfaces.dart';

void main() {
  group('ipv4Octets', () {
    test('parses a valid dotted address', () {
      expect(ipv4Octets('192.168.1.10'), [192, 168, 1, 10]);
    });

    test('rejects non-IPv4 values', () {
      expect(ipv4Octets('not.an.ip.addr'), isNull);
      expect(ipv4Octets('192.168.1'), isNull);
      expect(ipv4Octets('192.168.1.256'), isNull);
      expect(ipv4Octets('::1'), isNull);
      expect(ipv4Octets(''), isNull);
    });
  });

  group('privateIpv4Rank', () {
    test('ranks real LAN ranges ahead of virtual/VPN', () {
      expect(privateIpv4Rank([192, 168, 1, 5]), 0);
      expect(privateIpv4Rank([10, 0, 0, 5]), 1);
      expect(privateIpv4Rank([172, 16, 0, 5]), 2);
      expect(privateIpv4Rank([100, 64, 0, 5]), unrankedPrivateIpv4);
    });
  });

  group('isUsableLanIpv4', () {
    test('accepts private, rejects loopback/link-local/public', () {
      expect(isUsableLanIpv4([192, 168, 1, 5]), isTrue);
      expect(isUsableLanIpv4([127, 0, 0, 1]), isFalse);
      expect(isUsableLanIpv4([169, 254, 1, 1]), isFalse);
      expect(isUsableLanIpv4([8, 8, 8, 8]), isFalse);
    });
  });

  test('directedBroadcastIpv4 assumes /24', () {
    expect(directedBroadcastIpv4([192, 168, 1, 42]), '192.168.1.255');
  });

  group('subnetHostsIpv4', () {
    test('covers .1-.254 with no .0/.255 and no duplicates', () {
      final hosts = subnetHostsIpv4([192, 168, 1, 10]);
      expect(hosts.length, 254);
      expect(hosts.toSet().length, 254);
      expect(hosts.every((h) => h.startsWith('192.168.1.')), isTrue);
      expect(hosts.contains('192.168.1.0'), isFalse);
      expect(hosts.contains('192.168.1.255'), isFalse);
    });

    test('starts near the host octet and fans outward', () {
      final hosts = subnetHostsIpv4([192, 168, 1, 10]);
      expect(hosts.first, '192.168.1.10');
      expect(hosts.take(3), ['192.168.1.10', '192.168.1.9', '192.168.1.11']);
    });
  });

  group('preferredLanIpv4Octets', () {
    test('filters junk and orders real LAN before VPN', () {
      final ranked = preferredLanIpv4Octets([
        '10.8.0.2', // VPN-ish
        '127.0.0.1', // loopback, dropped
        '192.168.1.20', // real LAN, best
        'garbage',
      ]);
      expect(ranked, [
        [192, 168, 1, 20],
        [10, 8, 0, 2],
      ]);
    });
  });
}
