import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;

import 'lan_interfaces.dart';

/// Last-resort LAN discovery: actively probe every host on the local /24 for a
/// Pointy backend. Runs entirely in a background isolate (via [compute]) because
/// a /24 is up to 254 probes — doing it on the UI isolate would jank the app.
///
/// Only used when the fast path (stored IP + UDP broadcast) turned up nothing,
/// e.g. on networks where the AP/firewall silently drops broadcast frames.
///
/// Returns the advertised `api_base_url` of the first responder that is a
/// `pointy-backend` and (when [expectedInstallationId] is non-empty) belongs to
/// the expected shop, or an empty list.
Future<List<String>> sweepSubnetForBackends({
  String? expectedInstallationId,
  int port = 8000,
  Duration perProbeTimeout = const Duration(milliseconds: 400),
  int concurrency = 32,
}) {
  return compute(
    _sweepEntrypoint,
    _SweepArgs(
      expectedInstallationId: expectedInstallationId ?? '',
      port: port,
      perProbeTimeoutMs: perProbeTimeout.inMilliseconds,
      concurrency: concurrency,
    ),
  );
}

class _SweepArgs {
  const _SweepArgs({
    required this.expectedInstallationId,
    required this.port,
    required this.perProbeTimeoutMs,
    required this.concurrency,
  });

  final String expectedInstallationId;
  final int port;
  final int perProbeTimeoutMs;
  final int concurrency;
}

Future<List<String>> _sweepEntrypoint(_SweepArgs args) async {
  final hosts = await _lanHosts();
  if (hosts.isEmpty) {
    return const [];
  }
  final timeout = Duration(milliseconds: args.perProbeTimeoutMs);
  final httpClient = HttpClient()..connectionTimeout = timeout;
  final expected = args.expectedInstallationId;
  String? matched;
  var cursor = 0;

  Future<void> worker() async {
    while (matched == null) {
      final index = cursor++;
      if (index >= hosts.length) {
        break;
      }
      final apiBaseUrl = await _probeHost(
        httpClient,
        hosts[index],
        args.port,
        timeout,
        expected,
      );
      if (apiBaseUrl != null) {
        // First matching backend wins; other workers stop after their probe.
        matched ??= apiBaseUrl;
        break;
      }
    }
  }

  final workerCount = args.concurrency < hosts.length
      ? args.concurrency
      : hosts.length;
  await Future.wait([for (var w = 0; w < workerCount; w++) worker()]);
  httpClient.close(force: true);
  return matched == null ? const [] : [matched!];
}

Future<String?> _probeHost(
  HttpClient client,
  String host,
  int port,
  Duration timeout,
  String expected,
) async {
  try {
    final uri = Uri.parse('http://$host:$port/api/discovery/service/');
    final request = await client.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return null;
    }
    if (decoded['service']?.toString() != 'pointy-backend') {
      return null;
    }
    if (expected.isNotEmpty &&
        decoded['installation_id']?.toString() != expected) {
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
