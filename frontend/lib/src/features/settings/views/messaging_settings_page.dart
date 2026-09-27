import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/messaging_settings_view_model.dart';
import 'messaging_presentation.dart';
import 'messaging_settings_sections.dart';

/// Shop Settings sub-page for SMS.
///
/// SMS leaves through Daftar's relay on the company's provider account, as a
/// paid add-on — so there is nothing here to connect. The page says where the
/// shop stands (not in the subscription, switched off, or working and how much
/// of the month's allowance is gone), holds the shop's own brakes (the switch,
/// pacing, a daily cap, quiet hours for promotions), sends a test, and lists
/// every text Daftar sends so the shop knows exactly what its customers read.
class MessagingSettingsPage extends StatefulWidget {
  const MessagingSettingsPage({super.key, required this.viewModel});

  final MessagingSettingsViewModel viewModel;

  @override
  State<MessagingSettingsPage> createState() => _MessagingSettingsPageState();
}

class _MessagingSettingsPageState extends State<MessagingSettingsPage> {
  final _maxPerMinute = TextEditingController();
  final _dailyCap = TextEditingController();
  final _testPhone = TextEditingController();
  int _seededRevision = -1;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_seedControllers);
    _seedControllers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  /// Server state replacing the form (a load, a save) has to reach the text
  /// controllers too, or the fields keep showing what was typed while the view
  /// model holds what was stored.
  void _seedControllers() {
    final viewModel = widget.viewModel;
    if (viewModel.revision == _seededRevision) {
      return;
    }
    _seededRevision = viewModel.revision;
    _maxPerMinute.text = '${viewModel.maxMessagesPerMinute}';
    _dailyCap.text = '${viewModel.dailyCap}';
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_seedControllers);
    _maxPerMinute.dispose();
    _dailyCap.dispose();
    _testPhone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final saved = await widget.viewModel.save();
    if (saved && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.messagingSavedMessage)),
      );
    }
  }

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    await widget.viewModel.sendTest(_testPhone.text);
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    return PointyUnsavedChangesGuard(
      isDirty: () => viewModel.isDirty,
      onDiscard: viewModel.discardEdits,
      child: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context)!;
          return PointyScaffold(
            appBar: PointyAppBar(
              title: Text(l10n.messagingSettingsTitle),
              isLoading: viewModel.isBusy,
              actions: [
                IconButton(
                  tooltip: l10n.retryButton,
                  onPressed: viewModel.isBusy ? null : viewModel.load,
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
            body: _buildBody(context, l10n, viewModel),
          );
        },
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
  ) {
    if (!viewModel.hasStatus) {
      if (viewModel.hasLoadError) {
        return PointyErrorState(
          title: l10n.messagingLoadError,
          icon: Icons.sms_failed_outlined,
          action: FilledButton.icon(
            onPressed: viewModel.load,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return const PointyLoadingArea();
    }

    final spacing = AdaptiveSpacing.of(context);
    final usage = viewModel.usage;
    final sections = <Widget>[
      _buildHero(l10n, viewModel),
      ..._buildCallouts(l10n, viewModel),
      if (viewModel.isEntitled && usage != null)
        PointyDetailSection(
          icon: Icons.data_usage_outlined,
          title: l10n.messagingUsageTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MessagingUsageMeter(usage: usage),
              if (usage.isExhausted) ...[
                SizedBox(height: spacing.md),
                PointyDetailCallout(
                  icon: Icons.block_outlined,
                  tone: PointyCalloutTone.danger,
                  title: l10n.messagingLimitReachedTitle,
                  message: l10n.messagingLimitReachedMessage,
                ),
              ],
            ],
          ),
        ),
      if (viewModel.canEdit) _buildSettingsSection(context, l10n, viewModel),
      if (viewModel.canTest) _buildTestSection(context, l10n, viewModel),
      if (viewModel.templates.isNotEmpty)
        MessagingTemplatesSection(templates: viewModel.templates),
    ];

    return RefreshIndicator(
      onRefresh: viewModel.load,
      child: ListView(
        padding: spacing.pagePadding,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          AdaptiveMaxWidth(
            width: AppContentWidth.form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, section) in sections.indexed) ...[
                  if (index > 0) SizedBox(height: spacing.md),
                  section,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(AppLocalizations l10n, MessagingSettingsViewModel vm) {
    final lastSeen = vm.gateway?.lastSeenAt;
    final state = vm.serviceState;
    return PointyDetailHero(
      icon: Icons.sms_outlined,
      title: l10n.messagingHeroTitle,
      value: switch (state) {
        MessagingServiceState.notSubscribed =>
          l10n.messagingStatusNotSubscribed,
        MessagingServiceState.notReady => l10n.messagingStatusNotReady,
        MessagingServiceState.disabled => l10n.messagingStatusDisabled,
        MessagingServiceState.active => l10n.messagingStatusActive,
      },
      valueSubtitle: state == MessagingServiceState.notSubscribed
          ? l10n.messagingStatusNotSubscribedSubtitle
          : null,
      pills: [
        if (vm.isEntitled && vm.isTestMode)
          PointyHeroPill(
            icon: Icons.science_outlined,
            label: l10n.messagingTestModePill,
          ),
        if (vm.isEntitled && lastSeen != null)
          PointyHeroPill(
            icon: Icons.schedule_send_outlined,
            label: l10n.messagingLastSeenLabel(formatDateTime(lastSeen)),
          ),
        if (vm.isDirty)
          PointyHeroPill(
            icon: Icons.edit_outlined,
            label: l10n.messagingUnsavedBadge,
          ),
      ],
    );
  }

  /// The sentences under the hero, most decisive first: whether the shop has
  /// the service at all, whether it is on, then what is off about it.
  List<Widget> _buildCallouts(
    AppLocalizations l10n,
    MessagingSettingsViewModel vm,
  ) {
    final gateway = vm.gateway;
    return [
      switch (vm.serviceState) {
        MessagingServiceState.notSubscribed => PointyDetailCallout(
          icon: Icons.lock_outline,
          tone: PointyCalloutTone.neutral,
          title: l10n.messagingNotSubscribedTitle,
          message: l10n.messagingNotSubscribedMessage,
        ),
        MessagingServiceState.notReady => PointyDetailCallout(
          icon: Icons.hourglass_empty,
          tone: PointyCalloutTone.warning,
          title: l10n.messagingNotReadyTitle,
          message: l10n.messagingNotReadyMessage,
        ),
        MessagingServiceState.disabled => PointyDetailCallout(
          icon: Icons.pause_circle_outline,
          tone: PointyCalloutTone.warning,
          title: l10n.messagingDisabledTitle,
          message: l10n.messagingDisabledMessage,
        ),
        MessagingServiceState.active => null,
      },
      if (vm.isEntitled && vm.isTestMode)
        PointyDetailCallout(
          icon: Icons.science_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.messagingTestModeTitle,
          message: l10n.messagingTestModeMessage,
        ),
      if (vm.isUsageUnavailable)
        PointyDetailCallout(
          icon: Icons.cloud_off_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.messagingUsageUnavailableTitle,
          message: l10n.messagingUsageUnavailableMessage,
          trailing: TextButton(
            onPressed: vm.isBusy ? null : vm.load,
            child: Text(l10n.retryButton),
          ),
        ),
      if (vm.canEdit && gateway != null && gateway.hasError)
        PointyDetailCallout(
          icon: Icons.error_outline,
          tone: PointyCalloutTone.danger,
          title: l10n.messagingLastErrorTitle,
          message: _lastErrorText(l10n, vm),
        ),
    ].nonNulls.toList();
  }

  String _lastErrorText(AppLocalizations l10n, MessagingSettingsViewModel vm) {
    final gateway = vm.gateway!;
    final reason = messagingFailureMessage(
      l10n,
      code: gateway.lastErrorCode,
      detail: gateway.lastErrorDetail,
      fallback: gateway.lastError.trim(),
    );
    final when = gateway.lastErrorAt;
    return when == null
        ? reason
        : l10n.messagingLastErrorMessage(reason, formatDateTime(when));
  }

  Widget _buildSettingsSection(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel vm,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final enabled = !vm.isSaving;
    return PointyDetailSection(
      icon: Icons.tune_outlined,
      title: l10n.messagingSettingsSectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const ValueKey('messaging_service_switch'),
            contentPadding: EdgeInsets.zero,
            value: vm.isActive,
            title: Text(l10n.messagingServiceSwitchLabel),
            subtitle: Text(l10n.messagingServiceSwitchHelper),
            onChanged: enabled ? vm.setActive : null,
          ),
          SizedBox(height: spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _maxPerMinute,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (value) =>
                      vm.setMaxMessagesPerMinute(int.tryParse(value) ?? 0),
                  decoration: InputDecoration(
                    labelText: l10n.messagingRateLabel,
                    helperText: l10n.messagingRateHelper,
                    prefixIcon: const Icon(Icons.speed_outlined),
                  ),
                ),
              ),
              SizedBox(width: spacing.md),
              Expanded(
                child: TextField(
                  controller: _dailyCap,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (value) =>
                      vm.setDailyCap(int.tryParse(value) ?? 0),
                  decoration: InputDecoration(
                    labelText: l10n.messagingDailyCapLabel,
                    helperText: l10n.messagingRateHelper,
                    prefixIcon: const Icon(Icons.today_outlined),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.md),
          MessagingQuietHoursField(
            start: vm.quietHoursStart,
            end: vm.quietHoursEnd,
            hasIssue: vm.hasQuietHoursIssue,
            enabled: enabled,
            onStartChanged: vm.setQuietHoursStart,
            onEndChanged: vm.setQuietHoursEnd,
            onClear: vm.clearQuietHours,
          ),
          if (vm.saveFailed) ...[
            SizedBox(height: spacing.md),
            PointyDetailCallout(
              icon: Icons.error_outline,
              tone: PointyCalloutTone.danger,
              title: l10n.messagingSaveFailedTitle,
              message: messagingFailureMessage(
                l10n,
                code: vm.saveErrorCode,
                detail: vm.saveErrorDetail,
                fallback: l10n.messagingSaveError,
              ),
            ),
          ],
          SizedBox(height: spacing.lg),
          FilledButton.icon(
            key: const ValueKey('messaging_save'),
            onPressed: vm.canSave ? _save : null,
            icon: vm.isSaving
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(l10n.saveSettingsButton),
          ),
        ],
      ),
    );
  }

  Widget _buildTestSection(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel vm,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final canSend = !vm.isBusy && _testPhone.text.trim().isNotEmpty;
    final body = vm.testBody.trim();
    final result = switch (vm.testOutcome) {
      MessagingTestOutcome.sent => PointyDetailCallout(
        icon: Icons.check_circle_outline,
        tone: PointyCalloutTone.success,
        title: l10n.messagingTestSentTitle,
        message: body.isEmpty ? null : l10n.messagingTestSentBody(body),
      ),
      MessagingTestOutcome.queued => PointyDetailCallout(
        icon: Icons.schedule_send_outlined,
        tone: PointyCalloutTone.primary,
        title: l10n.messagingTestQueuedTitle,
        message: body.isEmpty ? null : l10n.messagingTestSentBody(body),
      ),
      MessagingTestOutcome.failed => PointyDetailCallout(
        icon: Icons.error_outline,
        tone: PointyCalloutTone.danger,
        title: l10n.messagingTestFailedTitle,
        message: messagingFailureMessage(
          l10n,
          code: vm.testErrorCode,
          detail: vm.testErrorDetail,
          fallback: l10n.messagingTestFailedMessage,
        ),
      ),
      MessagingTestOutcome.none || MessagingTestOutcome.sending => null,
    };

    return PointyDetailSection(
      icon: Icons.send_outlined,
      title: l10n.messagingTestTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('messaging_test_phone'),
            controller: _testPhone,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (canSend) _test();
            },
            decoration: InputDecoration(
              labelText: l10n.messagingTestPhoneLabel,
              hintText: l10n.messagingTestPhoneHint,
              helperText: l10n.messagingTestPhoneHelper,
              prefixIcon: const Icon(Icons.phone_outlined),
            ),
          ),
          SizedBox(height: spacing.md),
          FilledButton.icon(
            key: const ValueKey('messaging_test_send'),
            onPressed: canSend ? _test : null,
            icon: vm.isTesting
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: Text(l10n.messagingTestSendButton),
          ),
          if (result != null) ...[SizedBox(height: spacing.md), result],
        ],
      ),
    );
  }
}
