import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/services/connection_coordinator.dart';
import '../../../data/services/connection_status_controller.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';

/// Gates the app behind connection state: a spinner while discovery runs during
/// the startup cap, a manual IP/URL entry when auto-discovery gives up, and the
/// real [child] once a target (LAN or relay) is acquired.
class ConnectionGate extends StatelessWidget {
  const ConnectionGate({
    super.key,
    required this.controller,
    required this.coordinator,
    required this.child,
  });

  final ConnectionStatusController controller;
  final ConnectionCoordinator coordinator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return switch (controller.phase) {
          ConnectionPhase.connectedLocal ||
          ConnectionPhase.connectedRelay => child,
          ConnectionPhase.connecting => const _ConnectingScreen(),
          ConnectionPhase.needsManual => ManualConnectionScreen(
            controller: controller,
            coordinator: coordinator,
          ),
        };
      },
    );
  }
}

class _ConnectingScreen extends StatelessWidget {
  const _ConnectingScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyScaffold(
      body: PointyLoadingArea(label: l10n.connectionSearchingMessage),
    );
  }
}

/// Escape hatch shown after auto-discovery fails within the startup cap. The
/// user can type the server's IP/URL; the background sweep keeps running and
/// will dismiss this screen automatically if it finds the server first.
class ManualConnectionScreen extends StatefulWidget {
  const ManualConnectionScreen({
    super.key,
    required this.controller,
    required this.coordinator,
  });

  final ConnectionStatusController controller;
  final ConnectionCoordinator coordinator;

  @override
  State<ManualConnectionScreen> createState() => _ManualConnectionScreenState();
}

class _ManualConnectionScreenState extends State<ManualConnectionScreen> {
  final _controller = TextEditingController();
  bool _submitting = false;
  bool _failed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final value = _controller.text.trim();
    if (value.isEmpty || _submitting) {
      return;
    }
    setState(() {
      _submitting = true;
      _failed = false;
    });
    final connected = await widget.coordinator.connectManually(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _submitting = false;
      _failed = !connected;
    });
  }

  Future<void> _retryAuto() async {
    if (_submitting) {
      return;
    }
    setState(() => _failed = false);
    await widget.coordinator.rediscover();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;

    return PointyScaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: spacing.pagePadding,
          child: AdaptiveMaxWidth(
            width: AppContentWidth.compact,
            expand: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.wifi_find_outlined,
                  size: 44,
                  color: colors.mutedInk,
                ),
                SizedBox(height: spacing.md),
                Text(
                  l10n.connectionManualTitle,
                  textAlign: TextAlign.center,
                  style: textTheme.titleLarge,
                ),
                SizedBox(height: spacing.xs),
                Text(
                  l10n.connectionManualMessage,
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
                ),
                SizedBox(height: spacing.lg),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  // IPs and URLs read left-to-right even inside the RTL app.
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  enabled: !_submitting,
                  onSubmitted: (_) => _connect(),
                  decoration: InputDecoration(
                    labelText: l10n.connectionManualFieldLabel,
                    hintText: l10n.connectionManualFieldHint,
                    hintTextDirection: TextDirection.ltr,
                    prefixIcon: const Icon(Icons.dns_outlined),
                  ),
                ),
                if (_failed) ...[
                  SizedBox(height: spacing.md),
                  PointyInlineMessage.error(message: l10n.connectionManualError),
                ],
                SizedBox(height: spacing.lg),
                FilledButton.icon(
                  onPressed: _submitting ? null : _connect,
                  icon: _submitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: PointySpinner(strokeWidth: 2.4),
                        )
                      : const Icon(Icons.link),
                  label: Text(l10n.connectionManualConnectButton),
                ),
                SizedBox(height: spacing.sm),
                TextButton.icon(
                  onPressed: _submitting ? null : _retryAuto,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.connectionManualRetryButton),
                ),
                if (widget.controller.searchingInBackground) ...[
                  SizedBox(height: spacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox.square(
                        dimension: 14,
                        child: PointySpinner(strokeWidth: 2),
                      ),
                      SizedBox(width: spacing.xs),
                      Flexible(
                        child: Text(
                          l10n.connectionManualSearchingHint,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
