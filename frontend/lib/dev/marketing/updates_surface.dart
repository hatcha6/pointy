// Dev-only, safe to delete, never imported by lib/main.dart.
//
// The device's «تحديثات التطبيق» page against a fake update service:
//   updates             — a newer build is waiting on the shop's server
//   updates-downloading — that build arriving (the install was tapped)
//   updates-current     — already on the newest build
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/src/data/services/client_update_service.dart';
import 'package:pointy_frontend/src/features/settings/views/app_updates_page.dart';

import 'drive.dart';

const _running = '0.7.9';
const _offered = '0.8.0';

class UpdatesSurface extends StatefulWidget {
  const UpdatesSurface({super.key, required this.state});

  /// `available`, `downloading` or `current`.
  final String state;

  @override
  State<UpdatesSurface> createState() => _UpdatesSurfaceState();
}

class _UpdatesSurfaceState extends State<UpdatesSurface> {
  late final _service = _FakeUpdateService(upToDate: widget.state == 'current');

  @override
  void initState() {
    super.initState();
    if (widget.state == 'downloading') {
      // «تحديث الآن», pressed once the check has answered.
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 400),
        ).then((_) => pressFilledButton()),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AppUpdatesPage(service: _service);
}

class _FakeUpdateService extends ClientUpdateService {
  _FakeUpdateService({required this.upToDate}) : super(apiBaseUrl: () => '');

  final bool upToDate;

  @override
  Future<ClientUpdateStatus> check() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return ClientUpdateStatus(
      currentVersion: upToDate ? _offered : _running,
      platform: ClientPlatform.windows,
      available: upToDate
          ? null
          : const ClientRelease(
              version: _offered,
              file: 'pointy-setup-0.8.0.exe',
              sha256: '',
              size: 48 * 1024 * 1024,
              url: '',
            ),
    );
  }

  /// Arrives part-way and stays there, so the progress bar can be looked at.
  @override
  Future<void> downloadAndInstall(
    ClientRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    for (final step in const [0.18, 0.37, 0.52, 0.64]) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      onProgress?.call(step);
    }
    await Completer<void>().future;
  }
}
