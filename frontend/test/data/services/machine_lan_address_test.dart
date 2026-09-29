import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/lan_interfaces.dart';
import 'package:pointy_frontend/src/data/services/machine_lan_address.dart';

MachineAddressReader _machine(List<LanAddressCandidate> addresses) =>
    () async => addresses;

void main() {
  // A server PC on the WSL deployment: the real LAN, and WSL's own adapter in
  // the very same range.
  final serverPc = _machine([
    (interfaceName: 'vEthernet (WSL)', address: '192.168.176.1'),
    (interfaceName: 'Ethernet', address: '192.168.1.20'),
  ]);

  group('lanReachableUrl', () {
    test(
      'a loopback host becomes the LAN address, keeping port, path and fragment',
      () async {
        expect(
          await lanReachableUrl(
            'http://127.0.0.1:8000/c/#ABCD-2345',
            readAddresses: serverPc,
          ),
          'http://192.168.1.20:8000/c/#ABCD-2345',
        );
      },
    );

    test('localhost and ::1 are loopback too', () async {
      expect(
        await lanReachableUrl(
          'http://localhost:8000/c/#X',
          readAddresses: serverPc,
        ),
        'http://192.168.1.20:8000/c/#X',
      );
      expect(
        await lanReachableUrl(
          'http://[::1]:8000/c/#X',
          readAddresses: serverPc,
        ),
        'http://192.168.1.20:8000/c/#X',
      );
    });

    test("WSL's own address becomes the LAN address", () async {
      // Seen in the field: the till on the server PC reached the backend at
      // the VM's address, and the FTP page told the DVR to dial it.
      expect(
        await lanReachableUrl(
          'http://172.28.241.235:8000/api',
          readAddresses: _machine([
            (
              interfaceName: 'vEthernet (WSL (Hyper-V firewall))',
              address: '172.28.240.1',
            ),
            (interfaceName: 'Ethernet', address: '192.168.1.20'),
          ]),
        ),
        'http://192.168.1.20:8000/api',
      );
      expect(
        await lanReachableUrl(
          'http://192.168.183.42:8000/c/#X',
          readAddresses: serverPc,
        ),
        'http://192.168.1.20:8000/c/#X',
      );
    });

    test('an address that is already on the LAN is left alone', () async {
      expect(
        await lanReachableUrl(
          'http://192.168.1.5:8000/c/#X',
          readAddresses: serverPc,
        ),
        'http://192.168.1.5:8000/c/#X',
      );
    });

    test('a hostname is left alone without enumerating adapters', () async {
      var read = false;
      final url = await lanReachableUrl(
        'https://shop.relay.example/api',
        readAddresses: () async {
          read = true;
          return const [];
        },
      );
      expect(url, 'https://shop.relay.example/api');
      expect(read, isFalse, reason: 'a name means the same on every device');
    });

    test('with no LAN address the URL is kept rather than invented', () async {
      expect(
        await lanReachableUrl(
          'http://127.0.0.1:8000/c/#X',
          readAddresses: _machine(const []),
        ),
        'http://127.0.0.1:8000/c/#X',
      );
    });

    test('an adapter list that cannot be read keeps the URL', () async {
      expect(
        await lanReachableUrl(
          'http://127.0.0.1:8000/c/#X',
          readAddresses: () async => throw StateError('no interfaces'),
        ),
        'http://127.0.0.1:8000/c/#X',
      );
    });
  });
}
