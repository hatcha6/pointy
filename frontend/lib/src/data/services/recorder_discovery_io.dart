import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;

import 'lan_interfaces.dart';
import 'recorder_discovery.dart';
import 'recorder_identity.dart';

/// Where each brand keeps the one endpoint it will not serve anonymously.
///
/// Identification without a password rests on this: ask for the page, and the
/// device answers `401` with a digest challenge. A machine that is not that
/// brand answers `404`, so the challenge itself is the fingerprint.
const String _hikvisionProbePath = '/ISAPI/System/deviceInfo';
const String _dahuaProbePath = '/cgi-bin/magicBox.cgi?action=getDeviceType';

/// Whether an unauthenticated `200` body really came from the endpoint asked.
///
/// Needed because plenty of embedded web servers — routers especially, and
/// Pointy's own web app — answer `200` with their own page for every path on
/// the box. The decision lives in `recorder_identity.dart` so it can be tested
/// against real captured bodies without a socket; see [bodyIsFromDevice].
typedef _BodyCheck = bool Function(String body);

/// Enough to see the marker, not enough for a hostile responder to matter.
const int _maxBodySample = 4096;

/// The ONVIF device service, and the one call the spec requires a device to
/// answer without credentials.
const String _onvifProbePath = '/onvif/device_service';
const String _onvifProbeBody =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
    '<s:Body xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
    '<tds:GetSystemDateAndTime/></s:Body></s:Envelope>';

/// Xiongmai's own protocol port, and the whole of its fingerprint.
///
/// Unlike every other check here this is not HTTP: the port is simply open, and
/// on a shop LAN essentially nothing else uses it. That is much stronger
/// evidence than the port-80 content marker that once made every address of our
/// own server look like a Dahua — 34567 is unassigned and specific, where 80 is
/// shared with everything.
///
/// We deliberately do **not** complete a DVRIP handshake to be certain. That
/// would mean sending a login, and this firmware locks an account after a few
/// failed attempts: a sweep of a /24 could lock the shop out of its own
/// recorder. An open port is enough for a suggestion the installer confirms.
const int _dvripPort = 34567;

/// Ports worth trying. 80 is what both vendor brands ship on; 8080 is where an
/// installer moves it when something else already had 80; 8899 is where OEM
/// firmware usually puts ONVIF; 34567 is Xiongmai's own.
const List<int> _probePorts = [80, 8080, 8899, _dvripPort];

Future<List<DiscoveredRecorder>> discoverRecordersPlatform({
  Duration perProbeTimeout = const Duration(milliseconds: 400),
  int concurrency = 64,
}) {
  // A background isolate, like the backend sweep: a /24 is hundreds of socket
  // operations and doing them on the UI isolate janks the app that is showing
  // the progress spinner.
  return compute(
    _discoverEntrypoint,
    _DiscoveryArgs(
      perProbeTimeoutMs: perProbeTimeout.inMilliseconds,
      concurrency: concurrency,
    ),
  );
}

class _DiscoveryArgs {
  const _DiscoveryArgs({
    required this.perProbeTimeoutMs,
    required this.concurrency,
  });

  final int perProbeTimeoutMs;
  final int concurrency;
}

Future<List<DiscoveredRecorder>> _discoverEntrypoint(
  _DiscoveryArgs args,
) async {
  final hosts = await _lanHosts();
  if (hosts.isEmpty) {
    return const [];
  }
  final timeout = Duration(milliseconds: args.perProbeTimeoutMs);

  // Two stages, because they cost wildly different amounts. A TCP connect is
  // one round trip and can be run against all 254 hosts in about a second; an
  // HTTP request against 254 hosts is not. So: knock on every door, then only
  // talk to the ones that opened.
  final open = await _scanOpenPorts(hosts, timeout, args.concurrency);
  if (open.isEmpty) {
    return const [];
  }

  final client = HttpClient()..connectionTimeout = timeout;
  final found = <DiscoveredRecorder>[];
  try {
    // Also in parallel. A shop network has printers, access points and a
    // router all answering on :80, and identifying twenty of them two requests
    // at a time serially is fifteen seconds of a spinner — long enough that
    // people conclude it is broken and start typing.
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= open.length) {
          return;
        }
        final recorder = await _identify(client, open[index], timeout);
        if (recorder != null) {
          found.add(recorder);
        }
      }
    }

    const identifyConcurrency = 8;
    final workers = identifyConcurrency < open.length
        ? identifyConcurrency
        : open.length;
    await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  } finally {
    client.close(force: true);
  }
  // Back into sweep order, which is nearest-first, so the list does not depend
  // on which worker finished when.
  final rank = {
    for (var i = 0; i < open.length; i++) '${open[i].host}:${open[i].port}': i,
  };
  found.sort(
    (a, b) => (rank['${a.host}:${a.port}'] ?? 0).compareTo(
      rank['${b.host}:${b.port}'] ?? 0,
    ),
  );
  return _foldByHost(found);
}

class _Endpoint {
  const _Endpoint(this.host, this.port);

  final String host;
  final int port;
}

Future<List<_Endpoint>> _scanOpenPorts(
  List<String> hosts,
  Duration timeout,
  int concurrency,
) async {
  final targets = <_Endpoint>[
    for (final host in hosts)
      for (final port in _probePorts) _Endpoint(host, port),
  ];
  final open = <_Endpoint>[];
  var cursor = 0;

  Future<void> worker() async {
    while (true) {
      final index = cursor++;
      if (index >= targets.length) {
        return;
      }
      final target = targets[index];
      try {
        final socket = await Socket.connect(
          target.host,
          target.port,
          timeout: timeout,
        );
        socket.destroy();
        open.add(target);
      } on Object {
        // Closed, filtered, or nothing there. The overwhelming majority.
      }
    }
  }

  final workers = concurrency < targets.length ? concurrency : targets.length;
  await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  // Nearest-first, so the list the user sees is ordered the way the sweep
  // walked outward from this device rather than by whichever worker won.
  final order = {for (var i = 0; i < hosts.length; i++) hosts[i]: i};
  open.sort((a, b) {
    final byHost = (order[a.host] ?? 0).compareTo(order[b.host] ?? 0);
    return byHost != 0 ? byHost : a.port.compareTo(b.port);
  });
  return open;
}

Future<DiscoveredRecorder?> _identify(
  HttpClient client,
  _Endpoint endpoint,
  Duration timeout,
) async {
  if (endpoint.port == _dvripPort) {
    // Nothing to ask: the open port is the identification. See [_dvripPort]
    // for why we do not try to confirm it with a login.
    return DiscoveredRecorder(
      host: endpoint.host,
      port: 80,
      brand: brandFromProbe(const RecorderProbeOutcome(speaksDvrip: true)),
      model: '',
    );
  }
  final hikvision = await _probe(
    client,
    endpoint,
    _hikvisionProbePath,
    hikvisionBodyIsFromDevice,
    timeout,
  );
  final dahua = await _probe(
    client,
    endpoint,
    _dahuaProbePath,
    dahuaBodyIsFromDevice,
    timeout,
  );
  // Only asked when neither vendor answered: it is the fallback identity, and
  // a box that named itself has already told us something better.
  final onvif =
      hikvision == null && dahua == null
      ? await _probeOnvif(client, endpoint, timeout)
      : false;
  if (hikvision == null && dahua == null && !onvif) {
    return null;
  }

  final outcome = RecorderProbeOutcome(
    hikvisionRealm: hikvision?.realm,
    dahuaRealm: dahua?.realm,
    speaksOnvif: onvif,
  );
  final realm = hikvision?.realm.isNotEmpty == true
      ? hikvision!.realm
      : (dahua?.realm ?? '');
  return DiscoveredRecorder(
    host: endpoint.host,
    port: endpoint.port,
    brand: brandFromProbe(outcome),
    model: modelFromRealm(realm),
  );
}

class _ProbeResult {
  const _ProbeResult(this.realm);

  final String realm;
}

/// Ask the one ONVIF call that needs no credentials.
///
/// A POST rather than a GET, so it cannot be answered by a web server serving
/// its index page to everything — which is the failure this whole file learned
/// the hard way. Either the reply carries the response element or the box is
/// not ONVIF.
Future<bool> _probeOnvif(
  HttpClient client,
  _Endpoint endpoint,
  Duration timeout,
) async {
  try {
    final uri = Uri.parse(
      'http://${endpoint.host}:${endpoint.port}$_onvifProbePath',
    );
    final request = await client.postUrl(uri).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/soap+xml; charset=utf-8',
    );
    request.write(_onvifProbeBody);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(timeout);
      return false;
    }
    return onvifBodyIsFromDevice(await _sample(response, timeout));
  } on Object {
    return false;
  }
}

/// One row per machine, keeping the answer that tells us most.
List<DiscoveredRecorder> _foldByHost(List<DiscoveredRecorder> found) {
  final best = <String, DiscoveredRecorder>{};
  for (final recorder in found) {
    final existing = best[recorder.host];
    if (existing == null ||
        brandSpecificity(recorder.brand) > brandSpecificity(existing.brand) ||
        // Same brand, but one of them managed to read a serial off the realm.
        (recorder.brand == existing.brand &&
            existing.model.isEmpty &&
            recorder.model.isNotEmpty)) {
      best[recorder.host] = recorder;
    }
  }
  // Rebuild in the order they were found, which is nearest-first.
  final seen = <String>{};
  return [
    for (final recorder in found)
      if (seen.add(recorder.host)) best[recorder.host]!,
  ];
}

Future<_ProbeResult?> _probe(
  HttpClient client,
  _Endpoint endpoint,
  String path,
  _BodyCheck bodyIsGenuine,
  Duration timeout,
) async {
  try {
    final uri = Uri.parse('http://${endpoint.host}:${endpoint.port}$path');
    final request = await client.getUrl(uri).timeout(timeout);
    // Do not let dart:io answer the challenge for us: the 401 *is* the result.
    request.followRedirects = false;
    final response = await request.close().timeout(timeout);
    final challenge =
        response.headers.value(HttpHeaders.wwwAuthenticateHeader) ?? '';
    final status = response.statusCode;

    if (status == HttpStatus.unauthorized) {
      await response.drain<void>().timeout(timeout);
      return _ProbeResult(realmOf(challenge));
    }
    if (status != HttpStatus.ok) {
      await response.drain<void>().timeout(timeout);
      return null;
    }
    // Authentication turned off on the device — rare, and exactly the case
    // where a router's catch-all login page would otherwise pass for a
    // recorder. So the body has to be what this endpoint actually returns.
    final body = await _sample(response, timeout);
    return bodyIsGenuine(body) ? const _ProbeResult('') : null;
  } on Object {
    return null;
  }
}

Future<String> _sample(HttpClientResponse response, Duration timeout) async {
  final buffer = StringBuffer();
  try {
    await for (final chunk in response.timeout(timeout)) {
      buffer.write(String.fromCharCodes(chunk));
      if (buffer.length >= _maxBodySample) {
        break;
      }
    }
  } on Object {
    // A truncated read is still worth matching against.
  }
  final text = buffer.toString();
  return text.length > _maxBodySample
      ? text.substring(0, _maxBodySample)
      : text;
}

Future<List<String>> _lanHosts() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final octetsList = preferredLanIpv4Octets([
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ]);
    final hosts = <String>[];
    final seenSubnets = <String>{};
    for (final octets in octetsList) {
      final subnetKey = '${octets[0]}.${octets[1]}.${octets[2]}';
      if (!seenSubnets.add(subnetKey)) {
        continue;
      }
      hosts.addAll(subnetHostsIpv4(octets));
    }
    return hosts;
  } on Object {
    return const [];
  }
}
