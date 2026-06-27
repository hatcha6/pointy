import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/services/client_update_service.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';

/// "App updates" settings page: shows the running version and, when the local
/// backend advertises a newer build, lets the operator download + install it.
/// Never interrupts on its own — the update only runs when the user taps it.
class AppUpdatesPage extends StatefulWidget {
  const AppUpdatesPage({super.key, required this.service});

  final ClientUpdateService service;

  @override
  State<AppUpdatesPage> createState() => _AppUpdatesPageState();
}

class _AppUpdatesPageState extends State<AppUpdatesPage> {
  ClientUpdateStatus? _status;
  bool _checking = true;
  bool _installing = false;
  double _progress = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _failed = false;
    });
    final status = await widget.service.check();
    if (!mounted) return;
    setState(() {
      _status = status;
      _checking = false;
    });
  }

  Future<void> _install() async {
    final release = _status?.available;
    if (release == null) return;
    setState(() {
      _installing = true;
      _progress = 0;
      _failed = false;
    });
    try {
      await widget.service.downloadAndInstall(
        release,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appUpdatesPageTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _versionRow(context, l10n),
              const SizedBox(height: 24),
              Expanded(child: _body(context, l10n)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _versionRow(BuildContext context, AppLocalizations l10n) {
    final colors = context.pointyColors;
    return Row(
      children: [
        Icon(Icons.system_update_outlined, color: colors.primary),
        const SizedBox(width: 12),
        Expanded(child: Text(l10n.appUpdatesCurrentVersionLabel)),
        Text(
          _status?.currentVersion ?? '—',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    if (_checking) {
      return _centered(
        const CircularProgressIndicator(),
        l10n.appUpdatesChecking,
      );
    }
    final status = _status;
    if (status == null || status.unsupported) {
      return _centered(
        const Icon(Icons.cloud_done_outlined, size: 48),
        l10n.appUpdatesUnsupportedWeb,
      );
    }
    if (!status.hasUpdate) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_outline, size: 48),
          const SizedBox(height: 12),
          Text(l10n.appUpdatesUpToDate, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          TextButton(onPressed: _check, child: Text(l10n.appUpdatesRecheck)),
        ],
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.new_releases_outlined, size: 48),
        const SizedBox(height: 12),
        Text(l10n.appUpdatesAvailableLabel, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(
          status.available!.version,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),
        if (_installing) ...[
          LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          const SizedBox(height: 12),
          Text(l10n.appUpdatesDownloading, textAlign: TextAlign.center),
        ] else
          FilledButton.icon(
            onPressed: _install,
            icon: const Icon(Icons.download_outlined),
            label: Text(l10n.appUpdatesInstall),
          ),
        if (_failed) ...[
          const SizedBox(height: 12),
          Text(
            l10n.appUpdatesFailed,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.pointyColors.danger),
          ),
        ],
      ],
    );
  }

  Widget _centered(Widget icon, String message) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        icon,
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
      ],
    );
  }
}

/// Shows the QR + LAN link a fresh device can use to download the Pointy apps.
Future<void> showGetAppsDialog(
  BuildContext context, {
  required String downloadUrl,
}) {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.getAppsDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.getAppsInstructions, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Center(
            child: PointyQrImage(
              data: downloadUrl,
              size: 220,
              semanticsLabel: l10n.getAppsTitle,
            ),
          ),
          const SizedBox(height: 16),
          SelectableText(downloadUrl, textAlign: TextAlign.center),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: downloadUrl));
            messenger.showSnackBar(
              SnackBar(content: Text(l10n.getAppsLinkCopied)),
            );
          },
          child: Text(l10n.getAppsCopyLink),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
        ),
      ],
    ),
  );
}
