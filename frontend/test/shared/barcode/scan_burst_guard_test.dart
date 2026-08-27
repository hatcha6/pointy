import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/scan_burst_guard.dart';

void main() {
  final start = DateTime(2026, 1, 1, 12);

  test('human-paced digits are accepted', () {
    final guard = ScanBurstGuard();
    var now = start;

    expect(guard.onDigit('', now), isNull);
    now = now.add(const Duration(milliseconds: 300));
    expect(guard.onDigit('1', now), isNull);
    now = now.add(const Duration(milliseconds: 250));
    expect(guard.onDigit('12', now), isNull);
    expect(
      guard.shouldSwallowCommit(now.add(const Duration(milliseconds: 50))),
      isFalse,
    );
  });

  test('a scanner burst rolls pending entry back to its pre-burst value', () {
    final guard = ScanBurstGuard();
    var now = start;

    // Cashier had typed "3" at human pace…
    expect(guard.onDigit('', now), isNull); // typed '3'
    // …then a wedge fires: first burst digit looks human (came 500ms later)…
    now = now.add(const Duration(milliseconds: 500));
    expect(guard.onDigit('3', now), isNull); // burst '6' appended (unknowable)
    // …but the second burst digit arrives 20ms later and unmasks the wedge:
    // every subsequent keystroke rolls back to the pre-burst "3".
    now = now.add(const Duration(milliseconds: 20));
    expect(guard.onDigit('36', now), '3');
    now = now.add(const Duration(milliseconds: 20));
    expect(guard.onDigit('3', now), '3');
    now = now.add(const Duration(milliseconds: 20));
    expect(guard.onDigit('3', now), '3');
  });

  test('the burst terminator must not commit the pending entry', () {
    final guard = ScanBurstGuard();
    var now = start;

    guard.onDigit('', now);
    now = now.add(const Duration(milliseconds: 20));
    guard.onDigit('6', now);
    // Wedge Enter fires right after its last digit: swallow.
    expect(
      guard.shouldSwallowCommit(now.add(const Duration(milliseconds: 15))),
      isTrue,
    );
    // A human pressing Enter later is a deliberate commit.
    expect(
      guard.shouldSwallowCommit(now.add(const Duration(milliseconds: 500))),
      isFalse,
    );
  });

  test('a fresh human digit after a burst clears the cooling state', () {
    final guard = ScanBurstGuard();
    var now = start;

    guard.onDigit('', now);
    now = now.add(const Duration(milliseconds: 20));
    expect(guard.onDigit('6', now), isNotNull); // burst detected

    now = now.add(const Duration(milliseconds: 600));
    expect(guard.onDigit('', now), isNull); // human again
    expect(
      guard.shouldSwallowCommit(now.add(const Duration(milliseconds: 200))),
      isFalse,
    );
  });
}
