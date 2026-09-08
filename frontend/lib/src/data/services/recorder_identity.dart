/// Reading a recorder's identity out of what it says before anyone logs in.
///
/// Deliberately free of `dart:io` — like `lan_interfaces.dart` — so the part
/// that decides "is this a DVR, and whose?" compiles everywhere and is testable
/// without a network. The socket-bound sweep feeds raw header and body strings
/// through here.
library;

import '../models/camera.dart';

/// What each endpoint's *unauthenticated* success body looks like, for the
/// minority of devices with authentication turned off.
///
/// Dahua's magicBox CGI answers in flat `key=value` lines; Hikvision's ISAPI
/// answers in XML. Neither ever answers in HTML — see [bodyIsFromDevice].
const List<String> dahuaBodyMarkers = ['type=', 'deviceType='];
const List<String> hikvisionBodyMarkers = ['<DeviceInfo', '<ResponseStatus'];

/// Tells that a body is a web page rather than a device's control response.
///
/// Deliberately generous: a *missed* recorder can still be typed in by hand,
/// while a false one sends an installer to configure a machine that was never
/// a camera.
const List<String> _webPageTells = [
  '<!doctype html',
  '<html',
  '<head>',
  '<body',
  '<script',
  '<link ',
  '<meta ',
];

/// Whether an unauthenticated `200` really came from the endpoint we asked.
///
/// This is the guard that stops the sweep offering the shop its own server.
/// Pointy's own web app is served on port 80 behind an SPA catch-all
/// (`try_files $uri $uri/ /index.html`), so *every* path on it answers `200`
/// with the app shell — and that shell contains
/// `<link rel="icon" type="image/png" …>`, which a bare `contains('type=')`
/// read as a Dahua. Every address that reached the backend — both its NICs and
/// both Docker bridge gateways — was then listed as a recorder.
///
/// Two rules, either of which alone would have been enough:
///
/// * a body carrying the tells of a web page is never a device response;
/// * a `key=value` marker only counts at the *start of a line*, which is where
///   a CGI response puts its keys and where markup never puts them.
bool bodyIsFromDevice(
  String body,
  List<String> markers, {
  required bool keyValue,
}) {
  final lowered = body.toLowerCase();
  if (_webPageTells.any(lowered.contains)) {
    return false;
  }
  if (!keyValue) {
    return markers.any(body.contains);
  }
  for (final line in body.split('\n')) {
    final start = line.trimLeft();
    if (markers.any(start.startsWith)) {
      return true;
    }
  }
  return false;
}

/// [bodyIsFromDevice] for the Dahua CGI, whose answer is `key=value` lines.
bool dahuaBodyIsFromDevice(String body) =>
    bodyIsFromDevice(body, dahuaBodyMarkers, keyValue: true);

/// [bodyIsFromDevice] for the Hikvision ISAPI, whose answer is XML.
bool hikvisionBodyIsFromDevice(String body) =>
    bodyIsFromDevice(body, hikvisionBodyMarkers, keyValue: false);

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
