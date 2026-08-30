import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/messaging_settings_view_model.dart';

/// Shop Settings sub-page for the SMS device: point Pointy at the shop's SMS
/// Gate phone (base URL + credentials), tune the send pacing, activate the
/// device webhooks, and fire a Test-send.
///
/// The page is built around one truth the shop cannot otherwise see: saving is
/// not the same as working. A saved gateway can send; only an *activated* one
/// receives replies and delivery reports. So the status, the primary button and
/// the callouts all speak in terms of that three-step progression — not
/// configured → can send → fully connected — instead of a bare form that
/// reports "saved" and leaves the rest silent.
class MessagingSettingsPage extends StatefulWidget {
  const MessagingSettingsPage({super.key, required this.viewModel});

  final MessagingSettingsViewModel viewModel;

  @override
  State<MessagingSettingsPage> createState() => _MessagingSettingsPageState();
}

class _MessagingSettingsPageState extends State<MessagingSettingsPage> {
  final _baseUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _maxPerMinute = TextEditingController();
  final _dailyCap = TextEditingController();
  final _testPhone = TextEditingController();
  final _baseUrlFocus = FocusNode();
  bool _seeded = false;

  /// The address is only marked wrong once the user has left the field —
  /// flagging "invalid" against a half-typed IP is noise, not help.
  bool _baseUrlBlurred = false;
  int _seededRevision = -1;

  @override
  void initState() {
    super.initState();
    _baseUrlFocus.addListener(_onBaseUrlFocusChanged);
    widget.viewModel.addListener(_onViewModelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await widget.viewModel.load();
      if (mounted) _seedControllers();
    });
  }

  void _onBaseUrlFocusChanged() {
    if (!_baseUrlFocus.hasFocus && !_baseUrlBlurred) {
      setState(() => _baseUrlBlurred = true);
    } else {
      setState(() {});
    }
  }

  /// Server state replacing form state (a save, an activation, a reload) has to
  /// reach the text controllers too, or the fields keep showing what the user
  /// typed while the view model holds what was actually stored — e.g. the
  /// normalized address.
  void _onViewModelChanged() {
    if (_seeded && widget.viewModel.revision != _seededRevision) {
      _seedControllers();
    }
  }

  void _seedControllers() {
    final viewModel = widget.viewModel;
    _baseUrl.text = viewModel.baseUrl;
    _username.text = viewModel.username;
    _password.clear();
    _maxPerMinute.text = viewModel.maxMessagesPerMinute.toString();
    _dailyCap.text = viewModel.dailyCap.toString();
    _seededRevision = viewModel.revision;
    setState(() => _seeded = true);
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onViewModelChanged);
    _baseUrlFocus.removeListener(_onBaseUrlFocusChanged);
    _baseUrlFocus.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _maxPerMinute.dispose();
    _dailyCap.dispose();
    _testPhone.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _baseUrlBlurred = true);
    FocusScope.of(context).unfocus();
    await widget.viewModel.connect();
  }

  Future<void> _test() async {
    await widget.viewModel.sendTest(_testPhone.text);
  }

  @override
  Widget build(BuildContext context) {
    return PointyUnsavedChangesGuard(
      isDirty: () => widget.viewModel.isDirty,
      child: ListenableBuilder(
        listenable: widget.viewModel,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context)!;
          final viewModel = widget.viewModel;
          return PointyScaffold(
            appBar: PointyAppBar(
              title: Text(l10n.messagingSettingsTitle),
              isLoading: viewModel.isBusy,
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
    if (viewModel.isLoading && !_seeded) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && !viewModel.hasGateway) {
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

    final spacing = AdaptiveSpacing.of(context);
    return ListView(
      padding: spacing.pagePadding,
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHero(context, l10n, viewModel),
              SizedBox(height: spacing.md),
              ..._buildStatusCallouts(context, l10n, viewModel, spacing),
              _buildConnectionSection(context, l10n, viewModel),
              SizedBox(height: spacing.md),
              _buildTestSection(context, l10n, viewModel),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHero(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
  ) {
    final gateway = viewModel.gateway;
    final lastSeen = gateway?.lastSeenAt;
    return PointyDetailHero(
      icon: Icons.sms_outlined,
      title: l10n.messagingHeroTitle,
      value: switch (viewModel.setupStage) {
        MessagingSetupStage.ready => l10n.messagingStatusReady,
        MessagingSetupStage.configured => l10n.messagingStatusSendOnly,
        MessagingSetupStage.unconfigured => l10n.messagingStatusInactive,
      },
      pills: [
        const PointyHeroPill(
          icon: Icons.smartphone_outlined,
          label: 'SMS Gate',
        ),
        if (lastSeen != null)
          PointyHeroPill(
            icon: Icons.wifi_tethering,
            label: l10n.messagingLastSeenLabel(formatDateTime(lastSeen)),
          ),
        if (viewModel.isDirty)
          PointyHeroPill(
            icon: Icons.edit_outlined,
            label: l10n.messagingUnsavedBadge,
          ),
      ],
    );
  }

  /// The banners above the form, in priority order: what just happened, then
  /// what is still missing, then what the device last complained about.
  List<Widget> _buildStatusCallouts(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
    AdaptiveSpacing spacing,
  ) {
    final gateway = viewModel.gateway;
    final callouts = <Widget>[];

    switch (viewModel.connectOutcome) {
      case MessagingConnectOutcome.connected:
        callouts.add(
          PointyDetailCallout(
            icon: Icons.check_circle_outline,
            tone: PointyCalloutTone.success,
            title: l10n.messagingConnectedTitle,
            message: l10n.messagingConnectedMessage(
              viewModel.registeredWebhooks,
            ),
          ),
        );
      case MessagingConnectOutcome.savedNotActivated:
        // Two different stories share this outcome: a device that was never
        // activated (two-way messaging is simply off) and one that is activated
        // but unreachable right now (the existing webhooks still stand).
        callouts.add(
          PointyDetailCallout(
            icon: Icons.warning_amber_outlined,
            tone: PointyCalloutTone.warning,
            title: viewModel.isActivated
                ? l10n.messagingReactivateFailedTitle
                : l10n.messagingSavedNotActivatedTitle,
            message: viewModel.isActivated
                ? l10n.messagingReactivateFailedMessage
                : l10n.messagingSavedNotActivatedMessage,
          ),
        );
      case MessagingConnectOutcome.failed:
        callouts.add(
          PointyDetailCallout(
            icon: Icons.error_outline,
            tone: PointyCalloutTone.danger,
            title: l10n.messagingSaveFailedTitle,
            message: viewModel.connectDetail.isNotEmpty
                ? viewModel.connectDetail
                : l10n.messagingSaveError,
          ),
        );
      case MessagingConnectOutcome.none:
      case MessagingConnectOutcome.running:
        switch (viewModel.setupStage) {
          case MessagingSetupStage.unconfigured:
            callouts.add(
              PointyDetailCallout(
                icon: Icons.info_outline,
                tone: PointyCalloutTone.neutral,
                title: l10n.messagingSetupGuideTitle,
                message: l10n.messagingSetupGuideMessage,
              ),
            );
          case MessagingSetupStage.configured:
            callouts.add(
              PointyDetailCallout(
                icon: Icons.link_off_outlined,
                tone: PointyCalloutTone.warning,
                title: l10n.messagingNotActivatedTitle,
                message: l10n.messagingNotActivatedMessage,
              ),
            );
          case MessagingSetupStage.ready:
            break;
        }
    }

    // The device's own last complaint — the single most useful diagnostic on
    // the page, and previously reduced to an unexplained badge.
    if (gateway != null && gateway.hasError) {
      callouts.add(
        PointyDetailCallout(
          icon: Icons.error_outline,
          tone: PointyCalloutTone.danger,
          title: l10n.messagingDeviceErrorTitle,
          message: gateway.lastErrorAt == null
              ? gateway.lastError
              : l10n.messagingDeviceErrorMessage(
                  gateway.lastError,
                  formatDateTime(gateway.lastErrorAt!),
                ),
        ),
      );
    }

    return [
      for (final callout in callouts)
        Padding(
          padding: EdgeInsets.only(bottom: spacing.md),
          child: callout,
        ),
    ];
  }

  Widget _buildConnectionSection(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final showBaseUrlError =
        _baseUrlBlurred &&
        !_baseUrlFocus.hasFocus &&
        viewModel.baseUrlIssue == MessagingBaseUrlIssue.invalid;
    return PointyDetailSection(
      icon: Icons.settings_ethernet_outlined,
      title: l10n.messagingConnectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _baseUrl,
            focusNode: _baseUrlFocus,
            keyboardType: TextInputType.url,
            textDirection: TextDirection.ltr,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onChanged: viewModel.setBaseUrl,
            decoration: InputDecoration(
              labelText: l10n.messagingBaseUrlLabel,
              hintText: 'http://192.168.1.50:8080',
              prefixIcon: const Icon(Icons.link_outlined),
              errorText: showBaseUrlError ? l10n.messagingBaseUrlInvalid : null,
              // Once the field is at rest and the address will be stored
              // differently from what was typed (a missing scheme, a pasted
              // "/message" path), show the corrected form rather than fixing it
              // silently.
              helperText:
                  !_baseUrlFocus.hasFocus && viewModel.baseUrlWasNormalized
                  ? l10n.messagingBaseUrlNormalized(viewModel.normalizedBaseUrl)
                  : l10n.messagingBaseUrlHelper,
            ),
          ),
          SizedBox(height: spacing.md),
          TextField(
            controller: _username,
            textDirection: TextDirection.ltr,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onChanged: viewModel.setUsername,
            decoration: InputDecoration(
              labelText: l10n.messagingUsernameLabel,
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          SizedBox(height: spacing.md),
          PointyPasswordField(
            controller: _password,
            labelText: l10n.messagingPasswordLabel,
            prefixIcon: Icons.key_outlined,
            textDirection: TextDirection.ltr,
            textInputAction: TextInputAction.done,
            onChanged: viewModel.setPassword,
            onFieldSubmitted: (_) {
              if (viewModel.canConnect) _connect();
            },
            helperText: viewModel.hasStoredPassword
                ? l10n.messagingPasswordKeepHint
                : null,
          ),
          SizedBox(height: spacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _maxPerMinute,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (value) => viewModel.setMaxMessagesPerMinute(
                    int.tryParse(value) ?? 0,
                  ),
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
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (value) =>
                      viewModel.setDailyCap(int.tryParse(value) ?? 0),
                  decoration: InputDecoration(
                    labelText: l10n.messagingDailyCapLabel,
                    helperText: l10n.messagingRateHelper,
                    prefixIcon: const Icon(Icons.today_outlined),
                  ),
                ),
              ),
            ],
          ),
          // Clearing the rate field reads as 0 on the backend, which means "no
          // ceiling" — the opposite of what an emptied box looks like it means,
          // and the fastest way to get a consumer SIM flagged as a spammer.
          if (viewModel.isUnpaced) ...[
            SizedBox(height: spacing.md),
            PointyDetailCallout(
              icon: Icons.warning_amber_outlined,
              tone: PointyCalloutTone.warning,
              title: l10n.messagingUnpacedTitle,
              message: l10n.messagingUnpacedMessage,
            ),
          ],
          SizedBox(height: spacing.lg),
          FilledButton.icon(
            onPressed: viewModel.canConnect ? _connect : null,
            icon: viewModel.isSaving || viewModel.isActivating
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.link_outlined),
            label: Text(_connectLabel(l10n, viewModel)),
          ),
          Padding(
            padding: EdgeInsets.only(top: spacing.xs),
            child: Text(
              l10n.messagingConnectHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One primary action whose label says what pressing it will actually do:
  /// save-and-activate while there are edits, activate when the gateway is
  /// saved but unwired, re-register once everything is already connected.
  String _connectLabel(
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
  ) {
    if (viewModel.isSaving || viewModel.isActivating) {
      return l10n.messagingConnectingLabel;
    }
    if (viewModel.isDirty || !viewModel.hasGateway) {
      return l10n.messagingConnectButton;
    }
    return viewModel.isActivated
        ? l10n.messagingReactivateButton
        : l10n.messagingActivateOnlyButton;
  }

  Widget _buildTestSection(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final canTest = viewModel.canTest && _testPhone.text.trim().isNotEmpty;
    return PointyDetailSection(
      icon: Icons.send_outlined,
      title: l10n.messagingTestTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!viewModel.hasGateway)
            PointyDetailCallout(
              icon: Icons.info_outline,
              tone: PointyCalloutTone.neutral,
              title: l10n.messagingTestNeedsSaveTitle,
              message: l10n.messagingTestNeedsSaveMessage,
            )
          else ...[
            // A Test-send runs server-side against the stored gateway, so
            // running one over unsaved edits would report on settings that are
            // no longer on screen. Say that, instead of just greying out.
            if (viewModel.isDirty) ...[
              PointyDetailCallout(
                icon: Icons.save_outlined,
                tone: PointyCalloutTone.neutral,
                title: l10n.messagingUnsavedBadge,
                message: l10n.messagingUnsavedTestHint,
              ),
              SizedBox(height: spacing.md),
            ],
            TextField(
              controller: _testPhone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.done,
              enabled: viewModel.canTest,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (canTest) _test();
              },
              decoration: InputDecoration(
                labelText: l10n.messagingTestPhoneLabel,
                hintText: '+2189…',
                helperText: l10n.messagingTestPhoneHelper,
                prefixIcon: const Icon(Icons.phone_outlined),
              ),
            ),
            SizedBox(height: spacing.md),
            FilledButton.icon(
              onPressed: canTest ? _test : null,
              icon: viewModel.isTesting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(l10n.messagingTestSendButton),
            ),
            if (viewModel.testOutcome == MessagingTestOutcome.success) ...[
              SizedBox(height: spacing.md),
              PointyDetailCallout(
                icon: Icons.check_circle_outline,
                tone: PointyCalloutTone.success,
                title: l10n.messagingTestSentTitle,
                message: l10n.messagingTestSentMessage,
              ),
            ],
            if (viewModel.testOutcome == MessagingTestOutcome.failure) ...[
              SizedBox(height: spacing.md),
              PointyDetailCallout(
                icon: Icons.error_outline,
                tone: PointyCalloutTone.danger,
                title: l10n.messagingTestFailedTitle,
                message: viewModel.testMessage.isNotEmpty
                    ? viewModel.testMessage
                    : l10n.messagingTestFailedMessage,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
