/// Guards keyboard-driven quantity entry against barcode-wedge bursts.
///
/// A USB/Bluetooth scanner is just a keyboard that types very fast, so a pane
/// that turns loose digits into a pending line quantity would happily accept
/// "6291041500213" as a quantity if the cashier scans while a line is focused.
/// Humans can't sustain scanner speed: two digits closer together than
/// [burstGap] mean a wedge is typing, not a person.
///
/// The first digit of a burst is indistinguishable from human input, so the
/// guard snapshots the pending text before every "slow" digit; the moment a
/// second digit arrives at burst speed it hands that snapshot back so the
/// caller can roll the pending entry back to its pre-burst value. It then
/// stays "cooling" for the rest of the burst — trailing digits keep being
/// rejected and the terminating Enter must not commit anything.
class ScanBurstGuard {
  ScanBurstGuard({this.burstGap = const Duration(milliseconds: 80)});

  final Duration burstGap;

  DateTime? _lastDigitAt;
  String _preBurstPending = '';
  bool _cooling = false;

  /// Call before appending a digit (or decimal point) to the pending entry.
  ///
  /// Returns null when the keystroke is human-paced — append as usual. Returns
  /// the pre-burst pending text when this keystroke revealed (or continues) a
  /// scanner burst — restore that value and swallow the keystroke.
  String? onDigit(String currentPending, DateTime now) {
    final last = _lastDigitAt;
    _lastDigitAt = now;
    if (last == null || now.difference(last) > burstGap) {
      _cooling = false;
      _preBurstPending = currentPending;
      return null;
    }
    if (!_cooling) {
      _cooling = true;
      // _preBurstPending already holds the text from before the burst's first
      // digit (snapshotted when that digit arrived at human pace).
    }
    return _preBurstPending;
  }

  /// Whether a commit key (Enter) arriving [now] is the tail of a scanner
  /// burst and must be swallowed instead of applying the pending entry.
  bool shouldSwallowCommit(DateTime now) {
    final last = _lastDigitAt;
    if (!_cooling || last == null) {
      return false;
    }
    // A wedge's terminator follows its last digit near-instantly; a human
    // deciding to press Enter later than the burst gap is a real commit.
    return now.difference(last) <= burstGap;
  }

  void reset() {
    _lastDigitAt = null;
    _preBurstPending = '';
    _cooling = false;
  }
}
