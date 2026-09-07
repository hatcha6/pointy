import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/camera.dart';
import 'package:pointy_frontend/src/data/services/lan_interfaces.dart';
import 'package:pointy_frontend/src/data/services/recorder_identity.dart';

/// Naming a recorder from what it says before anyone logs in.
///
/// The sweep exists because most people configuring this have never typed an IP
/// address, so the risk it carries is a *confident wrong suggestion*: offering
/// the shop's router as their DVR is worse than offering nothing. These tests
/// are about what may and may not be claimed.
void main() {
  group('brandFromProbe', () {
    test('a box that guards only the ISAPI path is a Hikvision', () {
      expect(
        brandFromProbe(const RecorderProbeOutcome(hikvisionRealm: '')),
        RecorderBrand.hikvision,
      );
    });

    test('a box that guards only the Dahua CGI is a Dahua', () {
      expect(
        brandFromProbe(const RecorderProbeOutcome(dahuaRealm: '')),
        RecorderBrand.dahua,
      );
    });

    test('a box that answers neither is not a recorder', () {
      expect(
        brandFromProbe(const RecorderProbeOutcome()).name,
        RecorderBrand.auto.name,
      );
      expect(const RecorderProbeOutcome().isRecorder, isFalse);
    });

    test('a box that guards both is site-wide auth, and the realm decides', () {
      // Not a recorder speaking two dialects — a web server with one password
      // on everything. The realm is the only remaining evidence.
      expect(
        brandFromProbe(
          const RecorderProbeOutcome(
            hikvisionRealm: 'Login to 7K03A1BPAZ',
            dahuaRealm: 'Login to 7K03A1BPAZ',
          ),
        ),
        RecorderBrand.dahua,
      );
    });

    test('an ambiguous box is suggested without a brand, never guessed', () {
      // "auto" is the honest answer: the address is still worth offering, and
      // the backend settles the brand once it has a password.
      expect(
        brandFromProbe(
          const RecorderProbeOutcome(
            hikvisionRealm: 'Protected',
            dahuaRealm: 'Protected',
          ),
        ),
        RecorderBrand.auto,
      );
    });
  });

  group('brandFromRealm', () {
    test('reads the shapes each vendor actually ships', () {
      expect(brandFromRealm('Login to 7K03A1BPAZ1E2F3'), RecorderBrand.dahua);
      expect(brandFromRealm('IP Camera(C1234)'), RecorderBrand.hikvision);
      expect(brandFromRealm('DS-7216HGHI-K1'), RecorderBrand.hikvision);
      expect(brandFromRealm('NVR'), RecorderBrand.hikvision);
    });

    test('claims nothing about a realm it does not recognise', () {
      expect(brandFromRealm(''), RecorderBrand.auto);
      expect(brandFromRealm('Restricted Area'), RecorderBrand.auto);
      expect(brandFromRealm('TP-LINK Router'), RecorderBrand.auto);
    });
  });

  group('realmOf', () {
    test('reads the realm out of a digest challenge', () {
      expect(
        realmOf(
          'Digest qop="auth", realm="IP Camera(C1234)", '
          'nonce="4d3e...", stale="FALSE"',
        ),
        'IP Camera(C1234)',
      );
    });

    test('reads it out of a basic challenge too', () {
      // Some firmware still offers basic, and the realm is just as useful.
      expect(realmOf('Basic realm="Login to XYZ"'), 'Login to XYZ');
    });

    test('a header with no realm yields nothing rather than junk', () {
      expect(realmOf('Digest qop="auth", nonce="abc"'), '');
      expect(realmOf(''), '');
    });
  });

  group('modelFromRealm', () {
    test('strips the Dahua prefix so the serial is what shows', () {
      expect(modelFromRealm('Login to 7K03A1BPAZ1E2F3'), '7K03A1BPAZ1E2F3');
    });

    test('leaves a Hikvision product string alone', () {
      expect(modelFromRealm('DS-7216HGHI-K1'), 'DS-7216HGHI-K1');
    });

    test('a realm long enough to wrap the row is cut', () {
      final long = 'A' * 120;
      expect(modelFromRealm(long).length, 40);
    });
  });

  group('the addresses a sweep walks', () {
    test('starts at this device and fans outward', () {
      // So the first suggestion tends to be the nearest device rather than
      // whichever worker happened to finish first.
      final hosts = subnetHostsIpv4([192, 168, 1, 50]);
      expect(hosts.first, '192.168.1.50');
      expect(hosts.take(3), containsAll(['192.168.1.49', '192.168.1.51']));
      expect(hosts, hasLength(254));
      expect(hosts, isNot(contains('192.168.1.0')));
      expect(hosts, isNot(contains('192.168.1.255')));
    });

    test('a VPN or virtual adapter never outranks the real LAN', () {
      // A till with Hyper-V or a VPN up must still sweep the network the
      // cameras are on.
      final ranked = preferredLanIpv4Octets([
        '172.20.0.5',
        '192.168.1.50',
        '127.0.0.1',
        '169.254.4.4',
      ]);
      expect(ranked.first, [192, 168, 1, 50]);
      expect(ranked, hasLength(2));
    });
  });
}
