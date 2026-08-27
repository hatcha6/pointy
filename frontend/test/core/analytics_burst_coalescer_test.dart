// The `(_, __)` callbacks below read as redundant to a modern analyzer, and are
// not: the Win7/8 compat build pins Dart 3.3, where two `_` parameters in one
// signature is a compile error (wildcard variables landed later). This file is
// kept byte-identical across both branches so syncing it stays a copy.
// ignore_for_file: unnecessary_underscores

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_burst_coalescer.dart';

/// Collapsing a burst into one event is only safe if nothing is ever lost.
///
/// The two streams this serves — a held +/- key and a barcode scanner typing a
/// code — were 93.9% repeats and 1.46M individual keystrokes in the field. The
/// tests below are mostly about the boundaries: a run must end when the burst
/// really ends, and must still be emitted when something interrupts it.
void main() {
  /// Timers the test drives by hand, so a run's end is deterministic rather
  /// than a race against a real clock.
  late List<void Function()> pending;

  Timer schedule(Duration duration, void Function() callback) {
    pending.add(callback);
    return Timer(const Duration(days: 1), () {});
  }

  void fireIdleTimers() {
    final due = List<void Function()>.of(pending);
    pending.clear();
    for (final callback in due) {
      callback();
    }
  }

  setUp(() => pending = []);

  BurstCoalescer<int> coalescer({
    required void Function(String, CoalescedBurst<int>) onSettled,
    DateTime Function()? clock,
    Duration maxRunDuration = const Duration(seconds: 10),
  }) {
    return BurstCoalescer<int>(
      idleTimeout: const Duration(milliseconds: 400),
      maxRunDuration: maxRunDuration,
      onSettled: onSettled,
      clock: clock,
      scheduler: schedule,
    );
  }

  void addSample(BurstCoalescer<int> target, String key) {
    target.add(key, start: () => 1, merge: (current) => current + 1);
  }

  test('a burst becomes one event carrying the whole run', () {
    final settled = <CoalescedBurst<int>>[];
    final target = coalescer(onSettled: (_, burst) => settled.add(burst));

    for (var i = 0; i < 12; i += 1) {
      addSample(target, 'line-1');
    }
    expect(settled, isEmpty, reason: 'nothing is emitted mid-burst');

    fireIdleTimers();

    expect(settled, hasLength(1));
    expect(settled.single.count, 12);
    expect(settled.single.value, 12);
  });

  test('separate keys are separate runs', () {
    final settled = <String>[];
    final target = coalescer(onSettled: (key, _) => settled.add(key));

    addSample(target, 'line-1');
    addSample(target, 'line-2');
    fireIdleTimers();

    expect(settled, containsAll(<String>['line-1', 'line-2']));
  });

  test('an explicit settle ends the run immediately', () {
    // A scanner's Enter, or the cashier checking out — the run is over and
    // waiting for the idle timer would attribute it to the wrong moment.
    final settled = <CoalescedBurst<int>>[];
    final target = coalescer(onSettled: (_, burst) => settled.add(burst));

    addSample(target, 'k');
    addSample(target, 'k');
    target.settle('k');

    expect(settled, hasLength(1));
    expect(settled.single.count, 2);
  });

  test('settling something with no open run does nothing', () {
    var calls = 0;
    final target = coalescer(onSettled: (_, __) => calls += 1);

    target.settle('never-opened');
    target.settleAll();

    expect(calls, 0);
  });

  test('a run that never goes idle still reports', () {
    // A key held down forever must not accumulate silently, or a crash takes
    // the whole run with it.
    var now = DateTime.utc(2026, 8, 27, 12);
    final settled = <CoalescedBurst<int>>[];
    final target = coalescer(
      onSettled: (_, burst) => settled.add(burst),
      clock: () => now,
      maxRunDuration: const Duration(seconds: 2),
    );

    addSample(target, 'held');
    now = now.add(const Duration(seconds: 3));
    addSample(target, 'held');

    expect(settled, hasLength(1));
    expect(target.isOpen('held'), isFalse);
  });

  test('disposal emits what was still open', () {
    final settled = <CoalescedBurst<int>>[];
    final target = coalescer(onSettled: (_, burst) => settled.add(burst));

    addSample(target, 'k');
    target.dispose();

    expect(settled, hasLength(1), reason: 'a half-finished run is still real');
  });

  test('discarding drops runs that no longer describe anything', () {
    var calls = 0;
    final target = coalescer(onSettled: (_, __) => calls += 1);

    addSample(target, 'k');
    target.discardAll();
    fireIdleTimers();

    expect(calls, 0);
    expect(target.isOpen('k'), isFalse);
  });

  test('a settled run does not fire again when its timer comes due', () {
    var calls = 0;
    final target = coalescer(onSettled: (_, __) => calls += 1);

    addSample(target, 'k');
    target.settle('k');
    fireIdleTimers();

    expect(calls, 1, reason: 'the cancelled timer must not double-emit');
  });
}
