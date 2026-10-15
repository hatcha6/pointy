import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/local_server_host_controller.dart';

/// What the till on the shop's WSL server PC shows while that server starts:
/// in place of "searching for the server", since there is nothing to search
/// for until it runs. The connection gate takes over again once it answers.
class LocalServerStartingScreen extends StatelessWidget {
  const LocalServerStartingScreen({super.key, required this.controller});

  final LocalServerHostController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;
    final phase = controller.phase;

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
                Icon(Icons.dns_outlined, size: 44, color: colors.mutedInk),
                SizedBox(height: spacing.md),
                Text(
                  l10n.serverHostTitle,
                  textAlign: TextAlign.center,
                  style: textTheme.titleLarge,
                ),
                SizedBox(height: spacing.xs),
                Text(
                  l10n.serverHostStartingMessage,
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
                ),
                SizedBox(height: spacing.lg),
                if (phase == LocalServerHostPhase.starting ||
                    phase == LocalServerHostPhase.problem)
                  _StartSteps(step: controller.step),
                ..._statusFor(context, l10n, spacing),
                SizedBox(height: spacing.md),
                TextButton.icon(
                  onPressed: controller.connectElsewhere,
                  icon: const Icon(Icons.wifi_find_outlined),
                  label: Text(l10n.serverHostConnectElsewhereButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _statusFor(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    switch (controller.phase) {
      case LocalServerHostPhase.problem:
        return [
          SizedBox(height: spacing.md),
          PointyInlineMessage.warning(message: _problemText(l10n)),
          ..._setupNotice(l10n, spacing),
          SizedBox(height: spacing.md),
          FilledButton.icon(
            onPressed: controller.restartServer,
            icon: const Icon(Icons.restart_alt),
            label: Text(l10n.serverHostRestartButton),
          ),
          SizedBox(height: spacing.sm),
          _LogPath(path: controller.logPath),
        ];
      case LocalServerHostPhase.needsSetup:
        return [
          PointyInlineMessage.warning(
            message: l10n.serverHostNeedsSetupMessage,
          ),
          ..._setupNotice(l10n, spacing),
          SizedBox(height: spacing.md),
          FilledButton.icon(
            onPressed: controller.runSetup,
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: Text(l10n.serverHostSetupButton),
          ),
          if (controller.setupNotice == LocalServerSetupNotice.noAnswer) ...[
            SizedBox(height: spacing.sm),
            _LogPath(path: controller.logPath),
          ],
        ];
      case LocalServerHostPhase.settingUp:
        return [PointyLoadingArea(label: l10n.serverHostSetupRunning)];
      case LocalServerHostPhase.disabled:
        return [
          PointyInlineMessage.warning(message: l10n.serverHostDisabledMessage),
          SizedBox(height: spacing.sm),
          _LogPath(path: controller.logPath),
        ];
      case LocalServerHostPhase.inactive:
      case LocalServerHostPhase.starting:
      case LocalServerHostPhase.ready:
        return const [];
    }
  }

  String _problemText(AppLocalizations l10n) => switch (controller.problem) {
    LocalServerProblem.keeperSilent => l10n.serverHostKeeperSilentMessage,
    LocalServerProblem.wslNotAnswering => l10n.serverHostWslNotAnsweringMessage,
    LocalServerProblem.serverNotAnswering => l10n.serverHostProblemMessage,
  };

  /// Why the last setup or restart did not bring the keeper up, if it did not.
  List<Widget> _setupNotice(AppLocalizations l10n, AdaptiveSpacing spacing) {
    final text = switch (controller.setupNotice) {
      LocalServerSetupNotice.none => null,
      LocalServerSetupNotice.cancelled => l10n.serverHostSetupCancelled,
      LocalServerSetupNotice.missing => l10n.serverHostSetupMissing,
      LocalServerSetupNotice.failed => l10n.serverHostSetupFailed,
      LocalServerSetupNotice.noAnswer => l10n.serverHostSetupNoAnswer,
    };
    if (text == null) {
      return const [];
    }
    return [
      SizedBox(height: spacing.sm),
      PointyInlineMessage.error(message: text),
    ];
  }
}

/// The three steps of a start, the current one spinning.
class _StartSteps extends StatelessWidget {
  const _StartSteps({required this.step});

  final LocalServerStartStep step;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final labels = {
      LocalServerStartStep.launching: l10n.serverHostStageLaunching,
      LocalServerStartStep.waitingForWsl: l10n.serverHostStageWaitingForWsl,
      LocalServerStartStep.startingServices:
          l10n.serverHostStageStartingServices,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in labels.entries)
          Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.xs),
            child: _StepRow(
              label: entry.value,
              state: entry.key.index < step.index
                  ? _StepState.done
                  : entry.key == step
                  ? _StepState.current
                  : _StepState.pending,
            ),
          ),
      ],
    );
  }
}

enum _StepState { done, current, pending }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        SizedBox.square(
          dimension: 20,
          child: switch (state) {
            _StepState.done => Icon(
              Icons.check_circle,
              size: 20,
              color: colors.success,
            ),
            _StepState.current => const Padding(
              padding: EdgeInsets.all(2),
              child: PointySpinner(strokeWidth: 2.2),
            ),
            _StepState.pending => Icon(
              Icons.radio_button_unchecked,
              size: 20,
              color: colors.mutedInk,
            ),
          },
        ),
        SizedBox(width: spacing.sm),
        Expanded(
          child: Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              color: state == _StepState.pending ? colors.mutedInk : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _LogPath extends StatelessWidget {
  const _LogPath({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;
    final style = textTheme.bodySmall?.copyWith(color: colors.mutedInk);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.serverHostLogLabel, style: style),
        // A Windows path reads left-to-right inside the RTL app.
        SelectableText(path, textDirection: TextDirection.ltr, style: style),
      ],
    );
  }
}
