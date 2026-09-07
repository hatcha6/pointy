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

/// What each endpoint's *unauthenticated* success body looks like, for the
/// minority of devices with authentication turned off.
///
/// Needed because plenty of embedded web servers — routers especially — answer
/// `200` with their own login page for every path on the box. Without checking
/// the body, every router on the network would be suggested as a recorder.
const List<String> _hikvisionBodyMarkers = ['<DeviceInfo', '<ResponseStatus'];
const List<String> _dahuaBodyMarkers = ['type=', 'deviceType='];

/// Enough to see the marker, not enough for a hostile responder to matter.
const int _maxBodySample = 4096;

/// HTTP ports worth trying. 80 is what both brands ship on; 8080 is where an
/// installer moves it when something else already had 80.
const List<int> _probePorts = [80, 8080];

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
  return found;
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
  final hikvision = await _probe(
    client,
    endpoint,
    _hikvisionProbePath,
    _hikvisionBodyMarkers,
    timeout,
  );
  final dahua = await _probe(
    client,
    endpoint,
    _dahuaProbePath,
    _dahuaBodyMarkers,
    timeout,
  );
  if (hikvision == null && dahua == null) {
    return null;
  }

  final outcome = RecorderProbeOutcome(
    hikvisionRealm: hikvision?.realm,
    dahuaRealm: dahua?.realm,
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

Future<_ProbeResult?> _probe(
  HttpClient client,
  _Endpoint endpoint,
  String path,
  List<String> bodyMarkers,
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
    return bodyMarkers.any(body.contains) ? const _ProbeResult('') : null;
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
