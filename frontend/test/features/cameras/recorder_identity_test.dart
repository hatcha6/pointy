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

  group('bodyIsFromDevice', () {
    // The exact shell Pointy's own web app serves. Its SPA catch-all
    // (`try_files $uri $uri/ /index.html`) answers 200 for EVERY path, so the
    // sweep asked it for the Dahua CGI and got this back. The `type=` inside
    // the favicon link made it a Dahua, and every address that reached the
    // backend — both NICs and both Docker bridge gateways — was listed as a
    // recorder while the real DVR was never found. Sufian's shop, 2026-09-08.
    const pointyAppShell = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <link rel="icon" type="image/png" href="favicon.png"/>
  <title>دفتر</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

    test('our own web app is never mistaken for a Dahua', () {
      expect(dahuaBodyIsFromDevice(pointyAppShell), isFalse);
    });

    test('our own web app is never mistaken for a Hikvision', () {
      expect(hikvisionBodyIsFromDevice(pointyAppShell), isFalse);
    });

    test('a router login page is not a recorder either', () {
      expect(
        dahuaBodyIsFromDevice(
          '<html><body><form><input type="password"></form></body></html>',
        ),
        isFalse,
      );
    });

    test('the real Dahua CGI answer is still recognised', () {
      // What /cgi-bin/magicBox.cgi?action=getDeviceType actually returns.
      expect(dahuaBodyIsFromDevice('type=DHI-NVR4108HS-4KS2\r\n'), isTrue);
    });

    test('a Dahua answering with several keys is recognised', () {
      expect(
        dahuaBodyIsFromDevice('deviceType=NVR4116\nserialNumber=7K03A1B\n'),
        isTrue,
      );
    });

    test('the real Hikvision ISAPI answer is still recognised', () {
      expect(
        hikvisionBodyIsFromDevice(
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<DeviceInfo><model>DS-7208HQHI</model></DeviceInfo>',
        ),
        isTrue,
      );
    });

    test('a key=value marker only counts at the start of a line', () {
      // The whole point: `type=` buried in an attribute is markup, not a key.
      expect(
        dahuaBodyIsFromDevice('<input type="text"> and more type= text'),
        isFalse,
      );
    });

    test('an empty body claims nothing', () {
      expect(dahuaBodyIsFromDevice(''), isFalse);
      expect(hikvisionBodyIsFromDevice(''), isFalse);
    });
  });


  group('Xiongmai and ONVIF', () {
    test('its own protocol port names a Xiongmai', () {
      expect(
        brandFromProbe(const RecorderProbeOutcome(speaksDvrip: true)),
        RecorderBrand.xiongmai,
      );
    });

    test('the native protocol beats the standard one on the same box', () {
      // A Xiongmai answers ONVIF too. Naming it "ONVIF" would trade away the
      // channel names and recording search only its own protocol gives.
      expect(
        brandFromProbe(
          const RecorderProbeOutcome(speaksDvrip: true, speaksOnvif: true),
        ),
        RecorderBrand.xiongmai,
      );
    });

    test('a vendor dialect also beats the standard one', () {
      expect(
        brandFromProbe(
          const RecorderProbeOutcome(hikvisionRealm: '', speaksOnvif: true),
        ),
        RecorderBrand.hikvision,
      );
    });

    test('ONVIF alone is a real identification, just a lesser one', () {
      expect(
        brandFromProbe(const RecorderProbeOutcome(speaksOnvif: true)),
        RecorderBrand.onvif,
      );
      expect(const RecorderProbeOutcome(speaksOnvif: true).isRecorder, isTrue);
    });

    test('a box that answers nothing is still not a recorder', () {
      expect(const RecorderProbeOutcome().isRecorder, isFalse);
      expect(brandFromProbe(const RecorderProbeOutcome()), RecorderBrand.auto);
    });

    test('the ONVIF marker is the response element, not the request', () {
      // Echoing our own request back must not count as an answer.
      expect(onvifBodyIsFromDevice('<tds:GetSystemDateAndTime/>'), isFalse);
      expect(
        onvifBodyIsFromDevice(
          '<s:Body><tds:GetSystemDateAndTimeResponse>'
          '</tds:GetSystemDateAndTimeResponse></s:Body>',
        ),
        isTrue,
      );
    });

    test('our own web app is not ONVIF either', () {
      expect(
        onvifBodyIsFromDevice('<!DOCTYPE html><html><body>hi</body></html>'),
        isFalse,
      );
    });

    test('specificity orders the answers a single box can give', () {
      expect(
        brandSpecificity(RecorderBrand.xiongmai),
        greaterThan(brandSpecificity(RecorderBrand.hikvision)),
      );
      expect(
        brandSpecificity(RecorderBrand.hikvision),
        greaterThan(brandSpecificity(RecorderBrand.onvif)),
      );
      expect(
        brandSpecificity(RecorderBrand.onvif),
        greaterThan(brandSpecificity(RecorderBrand.auto)),
      );
    });
  });

}
