import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import 'lan_interfaces.dart';

/// Last-resort LAN discovery: actively probe every host on the local /24 for a
/// Pointy backend. Runs entirely in a background isolate (via [compute]) because
/// a /24 is up to 254 probes — doing it on the UI isolate would jank the app.
///
/// Only used when the fast path (stored IP + UDP broadcast) turned up nothing,
/// e.g. on networks where the AP/firewall silently drops broadcast frames.
///
/// A host gets [perProbeTimeout] to accept the connection — most addresses on
/// a /24 hold nothing, and they must cost little — but one that accepts gets
/// [answerTimeout] to answer: that is a server, and a busy one takes longer
/// than a connection does.
///
/// Returns the advertised `api_base_url` of the first responder that is a
/// `pointy-backend` and (when [expectedInstallationId] is non-empty) belongs to
/// the expected shop, or an empty list.
Future<List<String>> sweepSubnetForBackends({
  String? expectedInstallationId,
  int port = 8000,
  Duration perProbeTimeout = const Duration(milliseconds: 400),
  Duration answerTimeout = const Duration(seconds: 3),
  int concurrency = 32,
}) {
  return compute(
    _sweepEntrypoint,
    _SweepArgs(
      expectedInstallationId: expectedInstallationId ?? '',
      port: port,
      perProbeTimeoutMs: perProbeTimeout.inMilliseconds,
      answerTimeoutMs: answerTimeout.inMilliseconds,
      concurrency: concurrency,
    ),
  );
}

class _SweepArgs {
  const _SweepArgs({
    required this.expectedInstallationId,
    required this.port,
    required this.perProbeTimeoutMs,
    required this.answerTimeoutMs,
    required this.concurrency,
  });

  final String expectedInstallationId;
  final int port;
  final int perProbeTimeoutMs;
  final int answerTimeoutMs;
  final int concurrency;
}

Future<List<String>> _sweepEntrypoint(_SweepArgs args) async {
  final hosts = await _lanHosts();
  if (hosts.isEmpty) {
    return const [];
  }
  final connectTimeout = Duration(milliseconds: args.perProbeTimeoutMs);
  final answerTimeout = Duration(milliseconds: args.answerTimeoutMs);
  final httpClient = HttpClient()..connectionTimeout = connectTimeout;
  final found = Completer<String?>();
  var cursor = 0;

  Future<void> worker() async {
    while (!found.isCompleted) {
      final index = cursor++;
      if (index >= hosts.length) {
        return;
      }
      final apiBaseUrl = await probeHostForBackend(
        httpClient,
        hosts[index],
        args.port,
        connectTimeout: connectTimeout,
        answerTimeout: answerTimeout,
        expectedInstallationId: args.expectedInstallationId,
      );
      if (apiBaseUrl != null && !found.isCompleted) {
        found.complete(apiBaseUrl);
      }
    }
  }

  final workerCount = args.concurrency < hosts.length
      ? args.concurrency
      : hosts.length;
  unawaited(
    Future.wait([for (var w = 0; w < workerCount; w++) worker()]).then((_) {
      if (!found.isCompleted) {
        found.complete(null);
      }
    }),
  );
  // The first match ends the sweep: the other workers may be waiting out a
  // slow host, and nobody needs their answers any more.
  final matched = await found.future;
  httpClient.close(force: true);
  return matched == null ? const [] : [matched];
}

/// Asks [host] whether it is a Pointy backend, and for the shop
/// [expectedInstallationId] names when that is not empty. Returns the
/// `api_base_url` it advertises, or null.
@visibleForTesting
Future<String?> probeHostForBackend(
  HttpClient client,
  String host,
  int port, {
  required Duration connectTimeout,
  required Duration answerTimeout,
  String expectedInstallationId = '',
}) async {
  try {
    final uri = Uri.parse('http://$host:$port/api/discovery/service/');
    final request = await client.getUrl(uri).timeout(connectTimeout);
    final response = await request.close().timeout(answerTimeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(answerTimeout);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return null;
    }
    if (decoded['service']?.toString() != 'pointy-backend') {
      return null;
    }
    if (expectedInstallationId.isNotEmpty &&
        decoded['installation_id']?.toString() != expectedInstallationId) {
      return null;
    }
    final apiBaseUrl = decoded['api_base_url']?.toString() ?? '';
    return apiBaseUrl.isEmpty ? null : apiBaseUrl;
  } on Object {
    return null;
  }
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
