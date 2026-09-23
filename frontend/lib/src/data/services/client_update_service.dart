import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'linux_self_update.dart';
import 'machine_lan_address.dart';

/// The platforms that can self-update (download + install) from the local
/// backend. Enum names double as the platform keys in `/clients/manifest.json`.
enum ClientPlatform { android, windows, linux, unsupported }

ClientPlatform currentClientPlatform() {
  if (kIsWeb) return ClientPlatform.unsupported;
  if (Platform.isAndroid) return ClientPlatform.android;
  if (Platform.isWindows) return ClientPlatform.windows;
  if (Platform.isLinux) return ClientPlatform.linux;
  return ClientPlatform.unsupported;
}

/// Returns true when [remote] is a strictly newer dotted-numeric version than
/// [local]. Build suffixes (`+N`) and non-numeric noise are ignored, so
/// "1.4.0+12" vs "1.3.9" compares as 1.4.0 vs 1.3.9.
bool isNewerVersion(String remote, String local) {
  List<int> parse(String value) {
    final core = value.split('+').first.trim();
    if (core.isEmpty) return const [0];
    return core.split('.').map((part) {
      final match = RegExp(r'^\d+').firstMatch(part.trim());
      return match == null ? 0 : int.parse(match.group(0)!);
    }).toList();
  }

  final r = parse(remote);
  final l = parse(local);
  final length = r.length > l.length ? r.length : l.length;
  for (var i = 0; i < length; i += 1) {
    final rv = i < r.length ? r[i] : 0;
    final lv = i < l.length ? l[i] : 0;
    if (rv != lv) return rv > lv;
  }
  return false;
}

/// One platform's installer as advertised by the backend's `/clients/manifest.json`.
class ClientRelease {
  const ClientRelease({
    required this.version,
    required this.file,
    required this.sha256,
    required this.size,
    required this.url,
  });

  final String version;
  final String file;
  final String sha256;
  final int? size;
  final String url;

  factory ClientRelease.fromJson(Map<String, dynamic> json) => ClientRelease(
    version: (json['version'] ?? '').toString(),
    file: (json['file'] ?? '').toString(),
    sha256: (json['sha256'] ?? '').toString(),
    size: json['size'] is num ? (json['size'] as num).toInt() : null,
    url: (json['url'] ?? '').toString(),
  );
}

/// The result of an update check.
class ClientUpdateStatus {
  const ClientUpdateStatus({
    required this.currentVersion,
    required this.platform,
    this.available,
    this.unsupported = false,
    this.error,
  });

  final String currentVersion;
  final ClientPlatform platform;

  /// Non-null when the backend offers a newer build for this platform.
  final ClientRelease? available;

  /// True on web/other platforms that cannot self-update (managed by the backend).
  final bool unsupported;

  /// Set when the check could not complete (offline, on relay, etc.).
  final String? error;

  bool get hasUpdate => available != null;
}

/// Applies a downloaded build: hands off to the native installer on
/// Android/Windows (method channel); on Linux the portable tar.gz has no
/// installer, so a Dart-side handoff swaps the app bundle and relaunches.
class AppInstaller {
  const AppInstaller();

  static const MethodChannel _channel = MethodChannel('pointy/app_update');

  Future<void> install(ClientPlatform platform, String path) {
    switch (platform) {
      case ClientPlatform.android:
        return _channel.invokeMethod('installApk', {'path': path});
      case ClientPlatform.windows:
        return _channel.invokeMethod('runInstaller', {'path': path});
      case ClientPlatform.linux:
        return installLinuxUpdate(path);
      case ClientPlatform.unsupported:
        throw UnsupportedError('self-update is not supported on this platform');
    }
  }
}

/// Checks the local backend for a newer client build and applies it. The download
/// source is always the shop's own backend (LAN); when the device is on the relay
/// (no LAN backend) the manifest is unreachable and no update is offered.
class ClientUpdateService {
  ClientUpdateService({
    required String Function() apiBaseUrl,
    http.Client? client,
    AppInstaller installer = const AppInstaller(),
    Future<String> Function()? readRunningVersion,
    ClientPlatform Function()? platform,
    MachineAddressReader? localAddresses,
  }) : _apiBaseUrl = apiBaseUrl,
       _client = client ?? http.Client(),
       _installer = installer,
       _readRunningVersion = readRunningVersion ?? _packageVersion,
       _platform = platform ?? currentClientPlatform,
       _localAddresses = localAddresses ?? readMachineIpv4Addresses;

  final String Function() _apiBaseUrl;
  final http.Client _client;
  final AppInstaller _installer;
  final Future<String> Function() _readRunningVersion;
  final ClientPlatform Function() _platform;
  final MachineAddressReader _localAddresses;

  static Future<String> _packageVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  String _origin() {
    var base = _apiBaseUrl().trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.endsWith('/api')) base = base.substring(0, base.length - 4);
    return base;
  }

  /// The friendly LAN page a fresh device opens (QR/link target), on the web
  /// front-door port so a phone browser needs no port number. A loopback API
  /// host (the app runs on the server itself) becomes this machine's LAN
  /// address — see [lanReachableUrl].
  Future<String> lanDownloadUrl() async {
    final host = Uri.tryParse(_origin())?.host ?? '';
    if (host.isEmpty) return '${_origin()}/clients/';
    return lanReachableUrl(
      Uri(scheme: 'http', host: host, path: '/clients/').toString(),
      readAddresses: _localAddresses,
    );
  }

  Future<ClientUpdateStatus> check() async {
    final platform = _platform();
    final current = await _readRunningVersion();
    if (platform == ClientPlatform.unsupported) {
      return ClientUpdateStatus(
        currentVersion: current,
        platform: platform,
        unsupported: true,
      );
    }
    try {
      final response = await _client
          .get(Uri.parse('${_origin()}/clients/manifest.json'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        return ClientUpdateStatus(currentVersion: current, platform: platform);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final clients =
          (body['clients'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final entry = clients[platform.name];
      if (entry is! Map) {
        return ClientUpdateStatus(currentVersion: current, platform: platform);
      }
      final release = ClientRelease.fromJson(entry.cast<String, dynamic>());
      if (release.version.isNotEmpty &&
          isNewerVersion(release.version, current)) {
        return ClientUpdateStatus(
          currentVersion: current,
          platform: platform,
          available: release,
        );
      }
      return ClientUpdateStatus(currentVersion: current, platform: platform);
    } catch (error) {
      return ClientUpdateStatus(
        currentVersion: current,
        platform: platform,
        error: error.toString(),
      );
    }
  }

  Future<void> downloadAndInstall(
    ClientRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    final file = await _download(release, onProgress: onProgress);
    await _installer.install(_platform(), file.path);
  }

  Future<File> _download(
    ClientRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    final url = release.url.startsWith('http')
        ? release.url
        : '${_origin()}${release.url}';
    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('download failed (${response.statusCode})');
    }
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/${release.file}');
    final sink = out.openWrite();
    final total = release.size ?? response.contentLength ?? 0;
    var received = 0;
    await response.stream.forEach((chunk) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0 && onProgress != null) {
        onProgress(received / total);
      }
    });
    await sink.close();
    return out;
  }
}
