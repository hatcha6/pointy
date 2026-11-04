/// ONVIF WS-Discovery: the parts that need no socket.
///
/// The standard way to find ONVIF cameras and recorders — what ONVIF Device
/// Manager and the multi-brand camera apps use — is a SOAP `Probe` sent to the
/// WS-Discovery multicast group. Every ONVIF device on the segment answers with
/// a `ProbeMatch` naming its device service address (`XAddrs`) and a list of
/// `Scopes` describing itself. Unlike the TCP sweep it finds a device on
/// whatever port its firmware chose — 8000, 2020, 8999 — and it costs one
/// datagram rather than a connect per port per host.
///
/// Free of `dart:io`, like `recorder_identity.dart`, so reading a reply is
/// testable against captured payloads without a network.
library;

import 'dart:math';

import '../models/camera.dart';

const String wsDiscoveryMulticastAddress = '239.255.255.250';
const int wsDiscoveryPort = 3702;

/// The device service path nearly every firmware uses. Anything else is
/// carried to the backend, so its driver does not have to guess among the OEM
/// variants.
const String defaultOnvifServicePath = '/onvif/device_service';

/// The two types worth asking for. Cameras announce themselves as network
/// video transmitters; many recorders announce only the generic device type.
/// An empty probe would also wake every printer on the network.
const List<String> onvifProbeTypes = [
  'dn:NetworkVideoTransmitter',
  'tds:Device',
];

/// One `Probe` asking for devices of [type].
String onvifProbeMessage(String type, {Random? random}) {
  final messageId = _uuidV4(random ?? Random.secure());
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"'
      ' xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"'
      ' xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"'
      ' xmlns:dn="http://www.onvif.org/ver10/network/wsdl"'
      ' xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
      '<s:Header>'
      '<a:MessageID>uuid:$messageId</a:MessageID>'
      '<a:To s:mustUnderstand="1">'
      'urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>'
      '<a:Action s:mustUnderstand="1">'
      'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>'
      '</s:Header>'
      '<s:Body><d:Probe><d:Types>$type</d:Types></d:Probe></s:Body>'
      '</s:Envelope>';
}

/// What an ONVIF device said about itself in a `ProbeMatch`.
class OnvifAdvert {
  const OnvifAdvert({
    required this.host,
    required this.port,
    required this.servicePath,
    this.name = '',
    this.hardware = '',
    this.profiles = const {},
  });

  /// The address the reply came **from**, never the one it advertised.
  final String host;
  final int port;
  final String servicePath;
  final String name;
  final String hardware;

  /// Lower-cased profile names from the scopes: `streaming` (S), `g`, `t`.
  final Set<String> profiles;

  /// A label for telling two devices apart before either has been logged into.
  String get model {
    final value = hardware.isNotEmpty ? hardware : name;
    return value.length > 40 ? value.substring(0, 40).trim() : value;
  }
}

/// Reads one WS-Discovery reply, or null when it is not a usable `ProbeMatch`.
///
/// [senderHost] is the source address of the datagram, and it is used as the
/// device's host rather than the host inside `XAddrs`: cheap firmware
/// advertises an address it does not have — a stale DHCP lease, a factory
/// default, the documentation range — while the reply's own source is the one
/// address proven to reach it. The advertised port and path are still the
/// device's to say.
OnvifAdvert? parseOnvifProbeMatch(String xml, {required String senderHost}) {
  if (!_probeMatch.hasMatch(xml) || senderHost.isEmpty) {
    return null;
  }
  final address = _pickServiceAddress(
    _elementText(xml, 'XAddrs').split(_whitespace),
    senderHost,
  );
  if (address == null) {
    return null;
  }
  var name = '';
  var hardware = '';
  final profiles = <String>{};
  for (final scope in _elementText(xml, 'Scopes').split(_whitespace)) {
    final value = _scopeValue(scope, 'name');
    if (value != null) {
      name = value;
      continue;
    }
    final model = _scopeValue(scope, 'hardware');
    if (model != null) {
      hardware = model;
      continue;
    }
    final profile = _scopeValue(scope, 'profile');
    if (profile != null && profile.isNotEmpty) {
      profiles.add(profile.toLowerCase());
    }
  }
  return OnvifAdvert(
    host: senderHost,
    port: address.port,
    servicePath: address.path,
    name: name,
    hardware: hardware,
    profiles: profiles,
  );
}

/// The brand a discovered ONVIF device implies.
///
/// Hikvision and Dahua name themselves in their scopes. For them the vendor
/// protocol carries channel names and recording search that ONVIF may not, so
/// the answer is [RecorderBrand.auto]: the backend's detection tries the vendor
/// dialects first and settles it with the password in hand. Everything else is
/// what it says it is — an ONVIF device.
RecorderBrand brandFromOnvifAdvert(OnvifAdvert advert) {
  final text = '${advert.name} ${advert.hardware}'.toLowerCase();
  const vendorTells = ['hikvision', 'dahua'];
  if (vendorTells.any(text.contains)) {
    return RecorderBrand.auto;
  }
  return RecorderBrand.onvif;
}

final RegExp _probeMatch = RegExp(r'<(?:[\w.-]+:)?ProbeMatch\b');
final RegExp _whitespace = RegExp(r'\s+');

/// The text of the first element called [local], whatever its prefix.
String _elementText(String xml, String local) {
  final match = RegExp(
    '<(?:[\\w.-]+:)?$local\\b[^>]*>([\\s\\S]*?)</(?:[\\w.-]+:)?$local>',
  ).firstMatch(xml);
  return match?.group(1)?.trim() ?? '';
}

/// The value of an `onvif://www.onvif.org/<key>/<value>` scope, decoded.
String? _scopeValue(String scope, String key) {
  final prefix = 'onvif://www.onvif.org/$key/';
  if (!scope.toLowerCase().startsWith(prefix)) {
    return null;
  }
  final raw = scope.substring(prefix.length);
  try {
    return Uri.decodeComponent(raw).trim();
  } on ArgumentError {
    // A stray `%` in a firmware's name. The raw text still identifies it.
    return raw.trim();
  }
}

/// Port and path of the best device service address on offer.
///
/// Plain HTTP first (the recorder form has no way to carry TLS from here), and
/// the address matching the sender first among those, since a device that
/// lists several usually lists its real one too.
({int port, String path})? _pickServiceAddress(
  List<String> candidates,
  String senderHost,
) {
  final parsed = [
    for (final candidate in candidates)
      if (Uri.tryParse(candidate) case final uri?)
        if ((uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty)
          uri,
  ];
  if (parsed.isEmpty) {
    return null;
  }
  int rank(Uri uri) =>
      (uri.scheme == 'http' ? 0 : 2) + (uri.host == senderHost ? 0 : 1);
  parsed.sort((a, b) => rank(a).compareTo(rank(b)));
  final best = parsed.first;
  return (
    port: best.hasPort ? best.port : (best.scheme == 'https' ? 443 : 80),
    path: best.path.isEmpty ? defaultOnvifServicePath : best.path,
  );
}

String _uuidV4(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
