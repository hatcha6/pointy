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

  group('isLoopbackHost', () {
    test('names this machine in every spelling', () {
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('127.1.2.3'), isTrue);
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('LOCALHOST'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
    });

    test('a LAN address or a name is not loopback', () {
      expect(isLoopbackHost('192.168.1.10'), isFalse);
      expect(isLoopbackHost('pointy.local'), isFalse);
      expect(isLoopbackHost(''), isFalse);
    });
  });

  group('isVirtualAdapterName', () {
    test('knows the Windows adapters WSL, Hyper-V and VM hosts add', () {
      expect(isVirtualAdapterName('vEthernet (WSL)'), isTrue);
      expect(
        isVirtualAdapterName('vEthernet (WSL (Hyper-V firewall))'),
        isTrue,
      );
      expect(isVirtualAdapterName('vEthernet (Default Switch)'), isTrue);
      expect(isVirtualAdapterName('VirtualBox Host-Only Network'), isTrue);
      expect(isVirtualAdapterName('VMware Network Adapter VMnet8'), isTrue);
    });

    test('knows Linux container bridges and tunnels', () {
      expect(isVirtualAdapterName('docker0'), isTrue);
      expect(isVirtualAdapterName('br-3f2a9c1d'), isTrue);
      expect(isVirtualAdapterName('veth12ab'), isTrue);
      expect(isVirtualAdapterName('tun0'), isTrue);
      expect(isVirtualAdapterName('wg0'), isTrue);
    });

    test('leaves real adapters alone', () {
      expect(isVirtualAdapterName('Ethernet'), isFalse);
      expect(isVirtualAdapterName('Wi-Fi'), isFalse);
      expect(isVirtualAdapterName('Local Area Connection'), isFalse);
      expect(isVirtualAdapterName('eth0'), isFalse);
      expect(isVirtualAdapterName('wlan0'), isFalse);
      expect(isVirtualAdapterName('enp3s0'), isFalse);
    });
  });

  group('bestLanIpv4', () {
    test("a real adapter beats WSL's, even inside the same range", () {
      // WSL's NAT adapter often lands in 192.168.x, the same range the shop
      // router hands out, so the address range alone would be a coin toss —
      // and the phone given WSL's address can never reach it.
      expect(
        bestLanIpv4([
          (interfaceName: 'vEthernet (WSL)', address: '192.168.176.1'),
          (interfaceName: 'Ethernet', address: '192.168.1.20'),
        ]),
        '192.168.1.20',
      );
    });

    test('ranks the shop-router ranges among real adapters', () {
      expect(
        bestLanIpv4([
          (interfaceName: 'Ethernet 2', address: '172.16.4.9'),
          (interfaceName: 'Ethernet', address: '10.0.0.7'),
          (interfaceName: 'Wi-Fi', address: '192.168.0.5'),
        ]),
        '192.168.0.5',
      );
    });

    test('still uses a virtual adapter when it holds the only LAN address', () {
      // A Hyper-V external switch moves the real LAN address onto a vEthernet.
      expect(
        bestLanIpv4([
          (interfaceName: 'vEthernet (External)', address: '192.168.1.30'),
        ]),
        '192.168.1.30',
      );
    });

    test('nothing usable is null', () {
      expect(
        bestLanIpv4([
          (interfaceName: 'Loopback', address: '127.0.0.1'),
          (interfaceName: 'Wi-Fi', address: '169.254.3.4'),
          (interfaceName: 'Ethernet', address: '203.0.113.9'),
        ]),
        isNull,
      );
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
