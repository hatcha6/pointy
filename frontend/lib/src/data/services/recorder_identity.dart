/// Reading a recorder's identity out of what it says before anyone logs in.
///
/// Deliberately free of `dart:io` — like `lan_interfaces.dart` — so the part
/// that decides "is this a DVR, and whose?" compiles everywhere and is testable
/// without a network. The socket-bound sweep feeds raw header and body strings
/// through here.
library;

import '../models/camera.dart';

/// Which endpoint answered, if any. Both brands guard exactly one path that the
/// other returns 404 for, so *which* one challenges is the fingerprint.
class RecorderProbeOutcome {
  const RecorderProbeOutcome({this.hikvisionRealm, this.dahuaRealm});

  /// Non-null when the Hikvision ISAPI path answered as a device (a digest
  /// challenge, or a body only that endpoint returns). Empty string = answered
  /// but volunteered no realm.
  final String? hikvisionRealm;
  final String? dahuaRealm;

  bool get isRecorder => hikvisionRealm != null || dahuaRealm != null;
}

/// The brand a probe result implies.
///
/// A box that guards exactly one of the two paths has named itself. One that
/// guards both is a web server with site-wide authentication rather than a
/// recorder speaking two dialects, so the realm gets a vote — and when that is
/// inconclusive the answer is [RecorderBrand.auto]: the address is still worth
/// suggesting, and the backend settles the brand once it has a password.
RecorderBrand brandFromProbe(RecorderProbeOutcome outcome) {
  final hikvision = outcome.hikvisionRealm;
  final dahua = outcome.dahuaRealm;
  if (hikvision != null && dahua == null) {
    return RecorderBrand.hikvision;
  }
  if (dahua != null && hikvision == null) {
    return RecorderBrand.dahua;
  }
  if (hikvision == null && dahua == null) {
    return RecorderBrand.auto;
  }
  return brandFromRealm(dahua!.isNotEmpty ? dahua : hikvision!);
}

/// Dahua writes its realm as `Login to <serial>`; Hikvision writes the product
/// (`IP Camera(…)`, `DS-7216…`). Only ever used to break a tie.
RecorderBrand brandFromRealm(String realm) {
  final lowered = realm.trim().toLowerCase();
  if (lowered.isEmpty) {
    return RecorderBrand.auto;
  }
  if (lowered.startsWith('login to')) {
    return RecorderBrand.dahua;
  }
  if (lowered.contains('ip camera') ||
      lowered.contains('hikvision') ||
      lowered.startsWith('ds-') ||
      lowered.startsWith('nvr') ||
      lowered.startsWith('dvr')) {
    return RecorderBrand.hikvision;
  }
  return RecorderBrand.auto;
}

/// The realm out of a `WWW-Authenticate` header, whichever scheme it announces.
String realmOf(String challenge) {
  final match = RegExp(
    r'realm\s*=\s*"([^"]*)"',
    caseSensitive: false,
  ).firstMatch(challenge);
  return match?.group(1)?.trim() ?? '';
}

/// The human-readable half of a realm, for telling two recorders apart in a
/// list before either has been logged into. `Login to 7K03A1BPAZ` -> that
/// serial; `IP Camera(C1234)` -> the model.
String modelFromRealm(String realm) {
  var value = realm.trim();
  final lowered = value.toLowerCase();
  if (lowered.startsWith('login to')) {
    value = value.substring('login to'.length).trim();
  }
  // Some firmware pads the realm with the whole product string plus a serial;
  // 40 characters is enough to identify and short enough to sit on one line.
  return value.length > 40 ? value.substring(0, 40).trim() : value;
}
