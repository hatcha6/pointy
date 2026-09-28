import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/camera.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../ftp_setup_state.dart';
import '../view_models/camera_settings_view_model.dart';
import '../view_models/ftp_setup_view_model.dart';

/// Asks how a new recorder reaches Pointy. Null when the sheet is dismissed.
///
/// Asked first, and once: the two ways in need different fields entirely — an
/// address and a password to dial with, or nothing at all because the DVR is
/// the one that connects — and the choice cannot be changed afterwards.
Future<RecorderConnection?> showRecorderConnectionChoice(BuildContext context) {
  return showDialog<RecorderConnection>(
    context: context,
    builder: (context) {
      final l10n = AppLocalizations.of(context)!;
      return AdaptiveDialogSurface(
        // The explanations are the point of this dialog; the compact width
        // wrapped each one into a column of three-word lines.
        size: AdaptiveModalSize.standard,
        child: AlertDialog(
          title: Text(l10n.recorderConnectionChoiceTitle),
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          // Scrolls rather than overflows: each choice explains itself in a
          // sentence or two, and a phone held sideways has little height.
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ChoiceCard(
                  icon: Icons.lan_outlined,
                  title: l10n.recorderConnectionDirectTitle,
                  body: l10n.recorderConnectionDirectBody,
                  onTap: () =>
                      Navigator.of(context).pop(RecorderConnection.direct),
                ),
                const SizedBox(height: PointyDimensions.denseGap),
                _ChoiceCard(
                  icon: Icons.cloud_upload_outlined,
                  title: l10n.recorderConnectionFtpTitle,
                  body: l10n.recorderConnectionFtpBody,
                  onTap: () =>
                      Navigator.of(context).pop(RecorderConnection.ftp),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancelButton),
            ),
          ],
        ),
      );
    },
  );
}

/// One way to connect: a tappable card whose explanation wraps freely — a
/// list tile would clip it at two lines, and the explanation is the point.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: colors.primaryStrong),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
              const PointyDisclosureChevron(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Creates an FTP setup, or renames / switches off an existing one.
///
/// All an FTP setup needs from a person is a name. Creating one goes straight
/// on to its connection page, because the next thing the installer does is
/// type those credentials into the DVR.
class FtpRecorderFormPage extends StatefulWidget {
  const FtpRecorderFormPage({
    super.key,
    required this.viewModel,
    required this.initial,
  });

  final CameraSettingsViewModel viewModel;
  final RecorderDraft initial;

  @override
  State<FtpRecorderFormPage> createState() => _FtpRecorderFormPageState();
}

class _FtpRecorderFormPageState extends State<FtpRecorderFormPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial.name,
  );
  late bool _isEnabled = widget.initial.isEnabled;
  bool _failed = false;

  bool get _isNew => widget.initial.id == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final busy = widget.viewModel.isMutating;
        return PointyScaffold(
          appBar: PointyAppBar(title: Text(l10n.ftpFormTitle), isLoading: busy),
          body: ListView(
            padding: AdaptiveSpacing.of(context).pagePadding,
            children: [
              AdaptiveMaxWidth(
                width: AppContentWidth.form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_isNew) ...[
                      PointyInlineMessage(message: l10n.ftpFormIntro),
                      const SizedBox(height: PointyDimensions.sectionGap),
                    ],
                    TextField(
                      controller: _name,
                      autofocus: _isNew,
                      decoration: InputDecoration(
                        labelText: l10n.recorderNameLabel,
                        hintText: l10n.recorderNameHint,
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => busy ? null : unawaited(_save()),
                    ),
                    const SizedBox(height: PointyDimensions.denseGap),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _isEnabled,
                      onChanged: (value) => setState(() => _isEnabled = value),
                      title: Text(l10n.recorderEnabledLabel),
                    ),
                    if (_failed) ...[
                      const SizedBox(height: PointyDimensions.denseGap),
                      PointyInlineMessage.error(
                        message: l10n.recorderTestFailedTitle,
                      ),
                    ],
                    const SizedBox(height: PointyDimensions.sectionGap),
                    FilledButton.icon(
                      onPressed: busy ? null : () => unawaited(_save()),
                      icon: Icon(_isNew ? Icons.key_outlined : Icons.check),
                      label: Text(
                        _isNew ? l10n.ftpFormCreateAction : l10n.saveButton,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final viewModel = widget.viewModel;
    setState(() => _failed = false);
    if (_isNew) {
      final created = await viewModel.createFtpRecorder(
        name: _name.text.trim(),
        isEnabled: _isEnabled,
      );
      if (!mounted) {
        return;
      }
      if (created == null) {
        setState(() => _failed = true);
        return;
      }
      await navigator.pushReplacement(
        MaterialPageRoute<bool>(
          builder: (_) =>
              FtpConnectionPage(create: () => viewModel.ftpSetupFor(created)),
        ),
        result: true,
      );
      return;
    }
    final ok = await viewModel.saveRecorder(
      widget.initial.copyWith(name: _name.text.trim(), isEnabled: _isEnabled),
    );
    if (!mounted) {
      return;
    }
    if (ok) {
      navigator.pop(true);
    } else {
      setState(() => _failed = true);
    }
  }
}

/// What the installer types into the DVR, and whether it has worked yet.
///
/// Refreshes itself every few seconds while it is open (see
/// [FtpSetupViewModel]), so the result of pressing "Test" on the DVR appears
/// here on its own.
class FtpConnectionPage extends StatefulWidget {
  const FtpConnectionPage({super.key, required this.create});

  /// Builds the page's view model. The page owns what this returns and
  /// disposes it.
  final FtpSetupViewModel Function() create;

  @override
  State<FtpConnectionPage> createState() => _FtpConnectionPageState();
}

class _FtpConnectionPageState extends State<FtpConnectionPage> {
  late final FtpSetupViewModel _viewModel = widget.create();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_viewModel.start());
      }
    });
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = _viewModel;
        final account = viewModel.account;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.ftpConnectionTitle),
            isLoading: viewModel.isResolvingAddress || viewModel.isRegenerating,
          ),
          body: ListView(
            padding: AdaptiveSpacing.of(context).pagePadding,
            children: [
              AdaptiveMaxWidth(
                width: AppContentWidth.form,
                child: account == null
                    ? PointyInlineMessage.error(
                        message: l10n.recorderTestFailedTitle,
                      )
                    : FtpConnectionBody(
                        recorder: viewModel.recorder,
                        account: account,
                        status: viewModel.status!,
                        serverAddress: viewModel.serverAddress,
                        isResolvingAddress: viewModel.isResolvingAddress,
                        canManage: viewModel.canManage,
                        isRegenerating: viewModel.isRegenerating,
                        onRegenerate: () => unawaited(_confirmRegenerate()),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmRegenerate() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyConfirmationDialog(
        title: l10n.ftpRegenerateConfirmTitle,
        message: l10n.ftpRegenerateConfirmBody,
        confirmLabel: l10n.ftpRegenerateAction,
        icon: Icons.key_outlined,
      ),
    );
    if (confirmed == true && mounted) {
      await _viewModel.regeneratePassword();
    }
  }
}

/// The connection page's content, driven purely by its parameters so the
/// preview harness and the tests can render every state directly.
class FtpConnectionBody extends StatelessWidget {
  const FtpConnectionBody({
    super.key,
    required this.recorder,
    required this.account,
    required this.status,
    required this.serverAddress,
    required this.canManage,
    this.isResolvingAddress = false,
    this.isRegenerating = false,
    this.onRegenerate,
  });

  final Recorder recorder;
  final FtpAccountInfo account;
  final FtpSetupStatus status;
  final String? serverAddress;
  final bool isResolvingAddress;
  final bool canManage;
  final bool isRegenerating;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final server = account.server;
    final address = serverAddress;
    final password = account.password;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final message in ftpStatusMessages(l10n, status))
          Padding(
            padding: const EdgeInsets.only(bottom: PointyDimensions.denseGap),
            child: message,
          ),
        const SizedBox(height: PointyDimensions.denseGap),
        PointySectionHeader(title: recorder.displayName),
        const SizedBox(height: PointyDimensions.denseGap),
        Text(
          l10n.ftpConnectionIntro,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: PointyDimensions.denseGap),
        PointySettingsSection(
          children: [
            _CredentialTile(
              label: l10n.ftpServerLabel,
              value: address,
              placeholder: isResolvingAddress ? '…' : l10n.ftpAddressUnknown,
            ),
            _CredentialTile(label: l10n.ftpPortLabel, value: '${server.port}'),
            _CredentialTile(
              label: l10n.ftpUsernameLabel,
              value: account.username,
            ),
            _CredentialTile(
              label: l10n.ftpPasswordLabel,
              value: password,
              placeholder: l10n.ftpPasswordHidden,
            ),
          ],
        ),
        if (server.passivePorts.isNotEmpty) ...[
          const SizedBox(height: PointyDimensions.denseGap),
          Text(
            l10n.ftpPassivePortsHint(ltrIsolated(server.passivePorts)),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: PointyDimensions.sectionGap),
        PointySectionHeader(title: l10n.ftpStepsTitle),
        const SizedBox(height: PointyDimensions.denseGap),
        for (final (index, step) in [
          l10n.ftpStepEnter,
          l10n.ftpStepSchedule,
          l10n.ftpStepTest,
        ].indexed)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 12, child: Text('${index + 1}')),
            title: Text(step),
          ),
        if (account.filesReceived > 0) ...[
          const SizedBox(height: PointyDimensions.denseGap),
          Text(
            l10n.ftpStatsLine(
              '${account.filesReceived}',
              '${account.filesKept}',
              '${account.filesDiscarded}',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (canManage) ...[
          const SizedBox(height: PointyDimensions.sectionGap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: isRegenerating ? null : onRegenerate,
              icon: const Icon(Icons.key_outlined),
              label: Text(l10n.ftpRegenerateAction),
            ),
          ),
        ],
      ],
    );
  }
}

class _CredentialTile extends StatelessWidget {
  const _CredentialTile({
    required this.label,
    required this.value,
    this.placeholder = '',
  });

  final String label;
  final String? value;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final text = value;
    return ListTile(
      title: Text(label),
      subtitle: text == null || text.isEmpty
          ? Text(placeholder, style: TextStyle(color: colors.mutedInk))
          // Typed character by character into a DVR, so it is set large, in
          // a fixed-width face, and left to right however the screen reads.
          : Text(
              ltrIsolated(text),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Courier New', 'Menlo'],
                letterSpacing: 1.5,
                color: colors.ink,
              ),
            ),
      trailing: text == null || text.isEmpty
          ? null
          : IconButton(
              tooltip: l10n.ftpCopyTooltip,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: text)));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    content: Text(l10n.ftpCopiedMessage),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
    );
  }
}

/// A moment the way a shop reads it: the time today, the date otherwise.
String ftpMomentLabel(DateTime moment, {DateTime? now}) {
  final local = moment.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final sameDay =
      local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  return ltrIsolated(sameDay ? formatTime(local) : formatDateTime(local));
}

/// The one-line summary of an FTP setup, for the recorder card.
String ftpStatusSummary(AppLocalizations l10n, FtpSetupStatus status) {
  final at = status.at;
  final time = at == null ? '' : ftpMomentLabel(at);
  return switch (status.health) {
    FtpSetupHealth.serverDown => l10n.ftpStatusServerDown,
    FtpSetupHealth.refusingDisk => l10n.ftpStatusRefusingDisk,
    FtpSetupHealth.refusingInbox => l10n.ftpStatusRefusingInbox,
    // A Windows server sees every device at one forwarded address, so it
    // records none: saying so beats sending the installer to a wrong one.
    FtpSetupHealth.wrongPassword =>
      status.peer.isEmpty
          ? l10n.ftpStatusWrongPasswordNoAddress
          : l10n.ftpStatusWrongPassword(ltrIsolated(status.peer)),
    FtpSetupHealth.waiting => l10n.ftpStatusWaiting,
    FtpSetupHealth.loggedIn => l10n.ftpStatusLoggedIn(time),
    FtpSetupHealth.receiving => l10n.ftpStatusReceiving(time),
    FtpSetupHealth.stale => l10n.ftpStatusStale(time),
  };
}

/// Every message an FTP setup has for the person looking at it, most urgent
/// first: its state, then anything else going wrong beside it.
List<Widget> ftpStatusMessages(AppLocalizations l10n, FtpSetupStatus status) {
  final summary = ftpStatusSummary(l10n, status);
  final messages = <Widget>[
    switch (status.health) {
      FtpSetupHealth.serverDown || FtpSetupHealth.wrongPassword =>
        PointyInlineMessage.error(message: summary),
      FtpSetupHealth.receiving => PointyInlineMessage.success(message: summary),
      FtpSetupHealth.waiting => PointyInlineMessage(
        icon: Icons.hourglass_empty,
        message: summary,
      ),
      _ => PointyInlineMessage.warning(message: summary),
    },
  ];
  for (final login in status.unknownLogins) {
    messages.add(
      PointyInlineMessage.warning(
        icon: Icons.person_off_outlined,
        message: login.peer.isEmpty
            ? l10n.ftpStatusUnknownUserNoAddress(ltrIsolated(login.username))
            : l10n.ftpStatusUnknownUser(
                ltrIsolated(login.peer),
                ltrIsolated(login.username),
              ),
      ),
    );
  }
  if (status.ingestError.isNotEmpty) {
    messages.add(
      PointyInlineMessage.warning(
        message: l10n.ftpStatusUnreadable(status.ingestError),
      ),
    );
  }
  return messages;
}
