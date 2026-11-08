import '../../core/esim/esim_device.dart';
import '../../data/models/esim.dart';

/// What the eSIM page is for right now. Each mode has one main action.
enum EsimPageMode {
  /// On this phone, not installed yet: install it.
  install,

  /// For someone else, or this phone looks unable: send it.
  send,

  /// In use: what is left, and a top-up.
  active,

  /// Nearly out of data or time: top up now.
  low,

  /// Over for good: buy another.
  ended,
}

/// Works the mode out. An "active" status alone never counts as installed: the
/// network can report it before the eSIM is on any phone (Sandbox always does).
/// Installed means the customer said so, or some of its data has gone.
EsimPageMode esimPageMode({
  required CustomerEsim esim,
  required bool confirmedInstalled,
  required EsimSupport support,
  required DateTime now,
}) {
  final usage = esim.usage;
  if (esim.ended || (esim.install?.recycled ?? false)) {
    return EsimPageMode.ended;
  }
  if (usage.runningOut(now)) {
    return EsimPageMode.low;
  }
  final used = usage.totalMb > 0 && usage.remainingMb < usage.totalMb;
  if (confirmedInstalled || used) {
    return EsimPageMode.active;
  }
  return esim.gift || support == EsimSupport.no
      ? EsimPageMode.send
      : EsimPageMode.install;
}
