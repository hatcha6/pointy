import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/services/connection_coordinator.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Reaching the shop through the relay: the shop's installation ID (the owner
/// reads it from الإعدادات ← الاشتراك), then the shop's sign-in screen. Shown
/// from the manual-address screen, and as the whole of it in the web build
/// the relay serves, where there is no shop network to search.
class RelayConnectionForm extends StatefulWidget {
  const RelayConnectionForm({
    super.key,
    required this.coordinator,
    this.initialInstallationId = '',
    this.initialOutcome,
    this.onSearchLan,
  });

  final ConnectionCoordinator coordinator;
  final String initialInstallationId;

  /// What a try made before this form opened found, shown at once.
  final RemoteConnectOutcome? initialOutcome;

  /// Back to looking for the shop's server on this network; null where there
  /// is none to look on.
  final VoidCallback? onSearchLan;

  @override
  State<RelayConnectionForm> createState() => _RelayConnectionFormState();
}

class _RelayConnectionFormState extends State<RelayConnectionForm> {
  late final _controller = TextEditingController(
    text: widget.initialInstallationId,
  );
  bool _submitting = false;
  late RemoteConnectOutcome? _outcome = widget.initialOutcome;

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
      _outcome = null;
    });
    final outcome = await widget.coordinator.connectThroughRelay(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _submitting = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;
    final error = _errorMessage(l10n, _outcome);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.public, size: 44, color: colors.mutedInk),
        SizedBox(height: spacing.md),
        Text(
          l10n.connectionRemoteTitle,
          textAlign: TextAlign.center,
          style: textTheme.titleLarge,
        ),
        SizedBox(height: spacing.xs),
        Text(
          l10n.connectionRemoteMessage,
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
        ),
        SizedBox(height: spacing.lg),
        TextField(
          controller: _controller,
          autofocus: widget.initialInstallationId.isEmpty,
          // An ID reads left-to-right even inside the RTL app.
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.go,
          enabled: !_submitting,
          onSubmitted: (_) => _connect(),
          decoration: InputDecoration(
            labelText: l10n.connectionRemoteFieldLabel,
            hintText: l10n.connectionRemoteFieldHint,
            hintTextDirection: TextDirection.ltr,
            prefixIcon: const Icon(Icons.fingerprint),
          ),
        ),
        if (error != null) ...[
          SizedBox(height: spacing.md),
          PointyInlineMessage.error(message: error),
        ],
        SizedBox(height: spacing.lg),
        FilledButton.icon(
          onPressed: _submitting ? null : _connect,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2.4),
                )
              : const Icon(Icons.login),
          label: Text(l10n.connectionRemoteConnectButton),
        ),
        if (widget.onSearchLan case final onSearchLan?) ...[
          SizedBox(height: spacing.sm),
          TextButton.icon(
            onPressed: _submitting ? null : onSearchLan,
            icon: const Icon(Icons.wifi_find_outlined),
            label: Text(l10n.connectionRemoteSearchLanButton),
          ),
        ],
      ],
    );
  }
}

String? _errorMessage(AppLocalizations l10n, RemoteConnectOutcome? outcome) {
  return switch (outcome) {
    null ||
    RemoteConnectOutcome.connected ||
    RemoteConnectOutcome.signInRequired => null,
    RemoteConnectOutcome.notFound => l10n.connectionRemoteNotFound,
    RemoteConnectOutcome.disabled => l10n.connectionRemoteDisabled,
    RemoteConnectOutcome.shopOffline => l10n.connectionRemoteShopOffline,
    RemoteConnectOutcome.unreachable => l10n.connectionRemoteUnreachable,
  };
}
