import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/cups_pdf_spooler_io.dart';

/// The gap seek is a second CUPS job, and CUPS runs a queue's jobs one at a
/// time: the cashier sees a blank sticker feed, a pause, and only then the
/// label. These are the rules that decide when that is worth paying.
void main() {
  var now = DateTime(2026, 8, 28, 9);
  CupsLabelRegistration registration() =>
      CupsLabelRegistration(clock: () => now, ttl: const Duration(minutes: 5));

  setUp(() => now = DateTime(2026, 8, 28, 9));

  test('the first label job of the process seeks the gap', () {
    expect(registration().needsSeek('LPQ80'), isTrue);
  });

  test('a registered roll prints straight away', () {
    final rolls = registration()..markRegistered('LPQ80');
    expect(rolls.needsSeek('LPQ80'), isFalse);
  });

  test('registration is per queue', () {
    final rolls = registration()..markRegistered('LPQ80');
    expect(rolls.needsSeek('OtherPrinter'), isTrue);
  });

  test('a queue name is matched after trimming, and null reads as empty', () {
    final rolls = registration()..markRegistered(' LPQ80 ');
    expect(rolls.needsSeek('LPQ80'), isFalse);

    final defaultQueue = registration()..markRegistered(null);
    expect(defaultQueue.needsSeek(''), isFalse);
  });

  test('registration goes stale, because paper gets moved by hand', () {
    final rolls = registration()..markRegistered('LPQ80');
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(rolls.needsSeek('LPQ80'), isFalse);
    now = now.add(const Duration(seconds: 2));
    expect(rolls.needsSeek('LPQ80'), isTrue);
  });

  test('a run of prints does not push the deadline out', () {
    // Printing is not evidence that nobody touched the paper: the window is
    // measured from the seek that earned it, so a shop printing a label every
    // few minutes all day still re-registers on the same cadence.
    final rolls = registration()..markRegistered('LPQ80');
    for (var i = 0; i < 4; i++) {
      now = now.add(const Duration(minutes: 1));
      expect(rolls.needsSeek('LPQ80'), isFalse);
      rolls.markRegistered('LPQ80');
    }
    now = now.add(const Duration(minutes: 1, seconds: 1));
    expect(rolls.needsSeek('LPQ80'), isTrue);
  });

  test('anything else down the same queue costs the registration', () {
    // A receipt (or a calibration strip) leaves the roll wherever its content
    // ended, so the label phase this process knew is worthless.
    final rolls = registration()..markRegistered('LPQ80');
    rolls.forget('LPQ80');
    expect(rolls.needsSeek('LPQ80'), isTrue);
  });
}
