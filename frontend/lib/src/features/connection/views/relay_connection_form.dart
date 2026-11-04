import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/services/connection_coordinator.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../installation_id_text.dart';

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

  /// The field is drawn by Flutter, so a browser shows none of its own paste
  /// menu over it — on an iPhone there was no way to paste the ID at all.
  /// The clipboard is read instead, which a browser allows only inside a tap:
  /// the first tap on the empty field, then the «لصق» button. Safari answers
  /// that read with its own small «Paste» bubble.
  bool _clipboardTriedOnTap = false;
  bool _clipboardHasNoId = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // The paste button shows only while the field is empty.
    if (mounted) {
      setState(() {
        if (_controller.text.isNotEmpty) {
          _clipboardHasNoId = false;
        }
      });
    }
  }

  void _onFieldTap() {
    if (_clipboardTriedOnTap || _controller.text.trim().isNotEmpty) {
      return;
    }
    _clipboardTriedOnTap = true;
    _pasteFromClipboard(quietWhenNone: true);
  }

  /// Takes an installation ID from the clipboard and connects with it at
  /// once. With none there, says so — unless [quietWhenNone], for the read
  /// made on the field's first tap, where the paste button is answer enough.
  Future<void> _pasteFromClipboard({bool quietWhenNone = false}) async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on Object {
      // Refused, or dismissed (Safari's bubble): the same as nothing there.
      text = null;
    }
    if (!mounted || _submitting) {
      return;
    }
    final id = installationIdIn(text);
    if (id == null) {
      if (!quietWhenNone) {
        setState(() => _clipboardHasNoId = true);
      }
      return;
    }
    _controller.value = TextEditingValue(
      text: id,
      selection: TextSelection.collapsed(offset: id.length),
    );
    await _connect();
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
          // Not on the web: a focused field there is a browser input laid
          // over the canvas, so a tap on it never reaches [_onFieldTap] and
          // the clipboard is not read. On an iPhone autofocus raises no
          // keyboard anyway.
          autofocus: !kIsWeb && widget.initialInstallationId.isEmpty,
          // An ID reads left-to-right even inside the RTL app.
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.go,
          enabled: !_submitting,
          onTap: _onFieldTap,
          onSubmitted: (_) => _connect(),
          decoration: InputDecoration(
            labelText: l10n.connectionRemoteFieldLabel,
            hintText: l10n.connectionRemoteFieldHint,
            hintTextDirection: TextDirection.ltr,
            prefixIcon: const Icon(Icons.fingerprint),
            suffixIcon: _controller.text.isEmpty && !_submitting
                ? Padding(
                    padding: const EdgeInsetsDirectional.only(end: 4),
                    child: TextButton.icon(
                      key: const ValueKey('relay_paste_installation_id'),
                      onPressed: _pasteFromClipboard,
                      icon: const Icon(Icons.content_paste, size: 18),
                      label: Text(l10n.connectionRemotePasteButton),
                    ),
                  )
                : null,
          ),
        ),
        if (_clipboardHasNoId) ...[
          SizedBox(height: spacing.md),
          PointyInlineMessage(message: l10n.connectionRemoteClipboardHasNoId),
        ],
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
