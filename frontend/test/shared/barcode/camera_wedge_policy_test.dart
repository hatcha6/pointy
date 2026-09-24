import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_symbology.dart';

/// The misread these tests exist for is real and was measured, not imagined.
///
/// Pointing a camera at one product (`tools/camera-wedge-lab`), zxing-cpp read
/// its EAN-13 as three different wrong values in 24 scans — 12% — and every
/// wrong value passed the EAN-13 check digit. A till that believed any single
/// one of them would have sold a different product at a different price with
/// nothing looking wrong on any screen.
void main() {
  const truth = '3600523434725';
  // All three measured, all three checksum-valid, all three wrong.
  const misreads = ['9660323434725', '0608713434725', '9620723434725'];

  late DateTime now;
  CameraWedgePolicy policy() => CameraWedgePolicy(clock: () => now);

  setUp(() => now = DateTime(2026, 9, 22, 5));

  void tick([int ms = 13]) => now = now.add(Duration(milliseconds: ms));

  CameraWedgeScan? read(
    CameraWedgePolicy subject,
    String value, {
    String symbology = 'EAN13',
  }) => subject.offer(CameraWedgeReading(value: value, symbology: symbology));

  group('a 1-D read is never believed on its own', () {
    test('one look at a barcode emits nothing', () {
      final subject = policy();

      expect(read(subject, truth), isNull);
    });

    test('two agreeing looks emit it', () {
      final subject = policy();

      expect(read(subject, truth), isNull);
      tick();
      final scan = read(subject, truth);

      expect(scan, isNotNull);
      expect(scan!.value, truth);
      expect(scan.confirmations, 2);
    });

    test('a measured misread between two good reads emits nothing', () {
      // The exact interleaving the lab recorded: a hit, a disagreeing hit,
      // then more hits. Nothing may reach the cart until two IN A ROW agree.
      final subject = policy();

      expect(read(subject, truth), isNull);
      tick();
      expect(read(subject, misreads[0]), isNull);
      tick();
      expect(read(subject, truth), isNull);
      tick();
      final scan = read(subject, truth);

      expect(scan?.value, truth);
      expect(subject.rejectedDisagreements, 2);
    });

    test('every measured misread is rejected when read alone', () {
      for (final wrong in misreads) {
        final subject = policy();
        expect(read(subject, wrong), isNull, reason: wrong);
      }
    });

    test('two agreeing looks far apart are not corroboration', () {
      // The item may have been taken away and another put down. Agreement has
      // to be about the same object, which only closeness in time can say.
      final subject = policy();

      expect(read(subject, truth), isNull);
      tick(5000);

      expect(read(subject, truth), isNull);
    });
  });

  group('a 2-D read is believed at once', () {
    test('one look at a QR emits it', () {
      // Reed-Solomon means a decode that survives is trustworthy, which is
      // what makes the camera instant on the payment-terminal receipts the
      // counter wedge cannot read at all.
      final subject = policy();

      final scan = read(subject, 'pay://x/9f2', symbology: 'QRCode');

      expect(scan, isNotNull);
      expect(scan!.confirmations, 1);
    });

    test('Data Matrix, Aztec and PDF417 are trusted the same way', () {
      for (final symbology in [
        'DataMatrix',
        'Aztec',
        'PDF417',
        'MicroQRCode',
      ]) {
        final subject = policy();
        expect(
          read(subject, 'x', symbology: symbology),
          isNotNull,
          reason: symbology,
        );
      }
    });
  });

  group('an unknown or unprotected symbology is trusted least', () {
    test('Codabar needs three agreeing looks', () {
      final subject = policy();

      expect(read(subject, 'A123A', symbology: 'Codabar'), isNull);
      tick();
      expect(read(subject, 'A123A', symbology: 'Codabar'), isNull);
      tick();
      expect(read(subject, 'A123A', symbology: 'Codabar'), isNotNull);
    });

    test(
      'a symbology this code has never heard of gets the most suspicion',
      () {
        expect(
          CameraWedgeSymbology.classify('SomethingNewIn2030'),
          CameraWedgeSymbologyClass.unprotected,
        );
      },
    );

    test('spelling differences between decoders do not change trust', () {
      for (final spelling in ['QRCode', 'qr_code', 'QR-CODE', 'qrcode']) {
        expect(
          CameraWedgeSymbology.classify(spelling),
          CameraWedgeSymbologyClass.errorCorrected,
          reason: spelling,
        );
      }
      for (final spelling in ['EAN13', 'ean_13', 'EAN-13']) {
        expect(
          CameraWedgeSymbology.classify(spelling),
          CameraWedgeSymbologyClass.checkDigit,
          reason: spelling,
        );
      }
    });
  });

  group('a camera stares; a scanner reads once', () {
    test('an item left under the camera is not rung up twice', () {
      final subject = policy();
      read(subject, truth);
      tick();
      expect(read(subject, truth), isNotNull);

      // It keeps reading the same thing eighty times a second for as long as
      // the box sits there.
      for (var i = 0; i < 100; i += 1) {
        tick();
        expect(read(subject, truth), isNull);
      }
      expect(subject.suppressedRereads, 100);
    });

    test('the holdoff runs from the LAST look, not the first', () {
      // Otherwise a box left on the counter for two seconds re-emits while it
      // is still sitting there.
      final subject = policy();
      read(subject, truth);
      tick();
      expect(read(subject, truth), isNotNull);

      for (var i = 0; i < 30; i += 1) {
        tick(100); // 3 seconds, well past the 1.5s holdoff
        expect(read(subject, truth), isNull);
      }
    });

    test('the same item presented again after a pause is a new sale', () {
      final subject = policy();
      read(subject, truth);
      tick();
      expect(read(subject, truth), isNotNull);

      tick(2000); // taken away, brought back
      expect(read(subject, truth), isNull);
      tick();
      expect(read(subject, truth), isNotNull);
    });

    test('a different product under the camera is not held off', () {
      final subject = policy();
      read(subject, truth);
      tick();
      expect(read(subject, truth), isNotNull);

      tick();
      expect(read(subject, '5449000000996'), isNull);
      tick();
      expect(read(subject, '5449000000996'), isNotNull);
    });
  });

  group('a frame can hold more than one code', () {
    // The native wedge's C++ policy (src/test/policy_test.cpp) has the same
    // cases: the two implementations are one rule.
    CameraWedgeScan? frame(
      CameraWedgePolicy subject,
      List<(String, String)> codes,
    ) => subject.offerAll([
      for (final (value, symbology) in codes)
        CameraWedgeReading(value: value, symbology: symbology, at: now),
    ]);

    test('two codes in view are each scanned exactly once', () {
      // A box with its EAN beside a QR, left under the camera. With a single
      // "last scanned" value the two took turns being new, and the box was
      // rung up again and again for as long as it sat there.
      final subject = policy();
      final scanned = <String>[];
      for (var i = 0; i < 200; i += 1) {
        final scan = frame(subject, [
          (truth, 'EAN13'),
          ('https://brand.example/p/1', 'QRCode'),
        ]);
        if (scan != null) scanned.add(scan.value);
        tick(33);
      }

      expect(scanned, [truth, 'https://brand.example/p/1']);
    });

    test('a second code does not interrupt the first one\'s agreement', () {
      final subject = policy();
      expect(frame(subject, [(truth, 'EAN13')]), isNull);
      tick();

      // The QR appears too, listed first; the EAN being corroborated is still
      // the one that advances.
      final scan = frame(subject, [('pay://x', 'QRCode'), (truth, 'EAN13')]);

      expect(scan?.value, truth);
      expect(subject.rejectedDisagreements, 0);
    });

    test('a code repeated within one frame counts once', () {
      final subject = policy();

      expect(frame(subject, [(truth, 'EAN13'), (truth, 'EAN13')]), isNull);
    });

    test('an empty frame changes nothing', () {
      final subject = policy();
      expect(read(subject, truth), isNull);
      tick();
      expect(subject.offerAll(const []), isNull);
      tick();

      expect(read(subject, truth), isNotNull);
    });
  });

  test('reset forgets everything in flight', () {
    final subject = policy();
    expect(read(subject, truth), isNull);
    subject.reset();
    tick();

    // The pre-reset look must not pair with this one.
    expect(read(subject, truth), isNull);
  });

  test('a blank read is not a read', () {
    final subject = policy();
    expect(read(subject, '   '), isNull);
    tick();
    expect(read(subject, '   '), isNull);
  });
}
