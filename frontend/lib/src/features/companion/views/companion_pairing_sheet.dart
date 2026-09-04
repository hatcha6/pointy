import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/companion.dart';
import '../../../data/repositories/companion_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../companion_bridge.dart';

/// The one screen for lending a phone to this till: show the QR, watch the
/// phone arrive, then manage or silence it.
///
/// Pairing and management live together on purpose. A cashier who opens this is
/// asking "is my phone working?", and the answer — paired, connected, paused,
/// or nothing yet — belongs on the same screen as the fix.
Future<void> showCompanionPairingSheet(
  BuildContext context, {
  required CompanionRepository repository,
  required CompanionBridge bridge,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: CompanionPairingSheet(repository: repository, bridge: bridge),
    ),
  );
}

class CompanionPairingSheet extends StatefulWidget {
  const CompanionPairingSheet({
    super.key,
    required this.repository,
    required this.bridge,
  });

  final CompanionRepository repository;
  final CompanionBridge bridge;

  @override
  State<CompanionPairingSheet> createState() => _CompanionPairingSheetState();
}

class _CompanionPairingSheetState extends State<CompanionPairingSheet> {
  CompanionPairing? _pairing;
  bool _loading = true;
  bool _failed = false;
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Hold the channel open while the sheet is up, so the phone appears in the
    // list the instant it pairs rather than at the next roster refresh.
    widget.bridge.boost();
    unawaited(_createPairing());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.bridge.endBoost();
    super.dispose();
  }

  void _tick() {
    final pairing = _pairing;
    if (pairing == null || !mounted) return;
    setState(() => _remaining = pairing.expiresAt.difference(DateTime.now()));
  }

  Future<void> _createPairing() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final result = await widget.repository.createPairing(
      tillKey: widget.bridge.tillKey,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Ok(value: final pairing):
          _pairing = pairing;
          _remaining = pairing.expiresAt.difference(DateTime.now());
        case Error():
          _pairing = null;
          _failed = true;
      }
    });
  }

  Future<void> _setPaused(CompanionDevice device, bool paused) async {
    await widget.repository.setPaused(device.id, paused);
    await widget.bridge.refreshDevices();
  }

  Future<void> _unpair(CompanionDevice device) async {
    await widget.repository.unpair(device.id);
    await widget.bridge.refreshDevices();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: EdgeInsets.all(spacing.lg),
      children: [
        Text(
          l10n.companionSheetTitle,
          style: textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: spacing.xs),
        Text(
          l10n.companionSheetSubtitle,
          style: textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: spacing.lg),
        _buildPairingCard(context, l10n, spacing),
        SizedBox(height: spacing.lg),
        Text(l10n.companionPairedDevicesTitle, style: textTheme.titleMedium),
        SizedBox(height: spacing.sm),
        ValueListenableBuilder<CompanionStatus>(
          valueListenable: widget.bridge.status,
          builder: (context, status, _) {
            if (status.devices.isEmpty) {
              return PointyInlineMessage(
                compact: true,
                icon: Icons.smartphone_outlined,
                message: l10n.companionNoPairedDevices,
              );
            }
            return Column(
              children: [
                for (final device in status.devices)
                  _CompanionDeviceTile(
                    device: device,
                    onTogglePause: () => _setPaused(device, !device.isPaused),
                    onUnpair: () => _unpair(device),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildPairingCard(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: PointySpinner()),
      );
    }
    final pairing = _pairing;
    if (pairing == null || _failed) {
      return Column(
        children: [
          PointyInlineMessage.error(
            compact: true,
            message: l10n.companionPairingFailed,
          ),
          SizedBox(height: spacing.sm),
          TextButton(
            onPressed: _createPairing,
            child: Text(l10n.companionNewCode),
          ),
        ],
      );
    }

    final seconds = _remaining.inSeconds;
    final expired = seconds <= 0;
    return Column(
      children: [
        Text(l10n.companionScanQrInstruction, textAlign: TextAlign.center),
        SizedBox(height: spacing.md),
        // Dimmed rather than removed once expired, so the code stays
        // recognisable as "the thing that needs refreshing" instead of the
        // card emptying out under the cashier.
        Opacity(
          opacity: expired ? 0.25 : 1,
          child: Center(
            child: PointyQrImage(
              data: pairing.url,
              size: 240,
              semanticsLabel: l10n.companionSheetTitle,
            ),
          ),
        ),
        SizedBox(height: spacing.sm),
        Text(
          l10n.companionCodeFallbackLabel,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        // Latin letters and digits: isolate the direction so the code is not
        // reordered inside the Arabic sheet.
        Directionality(
          textDirection: TextDirection.ltr,
          child: SelectableText(
            pairing.code,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              letterSpacing: 6,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(height: spacing.xs),
        if (expired)
          FilledButton.icon(
            onPressed: _createPairing,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.companionNewCode),
          )
        else
          Text(
            l10n.companionCodeExpiresIn(seconds),
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _CompanionDeviceTile extends StatelessWidget {
  const _CompanionDeviceTile({
    required this.device,
    required this.onTogglePause,
    required this.onUnpair,
  });

  final CompanionDevice device;
  final VoidCallback onTogglePause;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final lastSeen = device.lastSeenAt;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        device.isPaused ? Icons.pause_circle_outline : Icons.smartphone,
        color: device.isPaused ? context.pointyColors.mutedInk : null,
      ),
      title: Text(device.label.isEmpty ? device.address : device.label),
      subtitle: lastSeen == null
          ? null
          : Text(
              l10n.companionDeviceLastSeen(
                TimeOfDay.fromDateTime(lastSeen).format(context),
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: onTogglePause,
            child: Text(
              device.isPaused ? l10n.companionResume : l10n.companionPause,
            ),
          ),
          IconButton(
            tooltip: l10n.companionUnpair,
            onPressed: onUnpair,
            icon: const Icon(Icons.link_off),
          ),
        ],
      ),
    );
  }
}
