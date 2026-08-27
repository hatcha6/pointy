import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/messaging_settings_view_model.dart';

/// Shop Settings sub-page for the SMS device: point Pointy at the shop's SMS
/// Gate phone (base URL + credentials), tune the send pacing, and fire a
/// Test-send. Mirrors the subscription status page's structure.
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
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await widget.viewModel.load();
      if (mounted) _seedControllers();
    });
  }

  void _seedControllers() {
    final viewModel = widget.viewModel;
    _baseUrl.text = viewModel.baseUrl;
    _username.text = viewModel.username;
    _maxPerMinute.text = viewModel.maxMessagesPerMinute.toString();
    _dailyCap.text = viewModel.dailyCap.toString();
    setState(() => _seeded = true);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _maxPerMinute.dispose();
    _dailyCap.dispose();
    _testPhone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final ok = await widget.viewModel.save();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.messagingSavedMessage : l10n.messagingSaveError),
      ),
    );
  }

  Future<void> _activate() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.viewModel.activate();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result != null && result.ok
              ? l10n.messagingActivatedMessage(result.registered)
              : l10n.messagingActivateError,
        ),
      ),
    );
  }

  Future<void> _test() async {
    await widget.viewModel.sendTest(_testPhone.text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
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
              if (!viewModel.isConfigured)
                Padding(
                  padding: EdgeInsets.only(bottom: spacing.md),
                  child: PointyDetailCallout(
                    icon: Icons.info_outline,
                    tone: PointyCalloutTone.neutral,
                    title: l10n.messagingNotConfiguredTitle,
                    message: l10n.messagingNotConfiguredMessage,
                  ),
                ),
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
    return PointyDetailHero(
      icon: Icons.sms_outlined,
      title: l10n.messagingHeroTitle,
      value: viewModel.isConfigured
          ? l10n.messagingStatusActive
          : l10n.messagingStatusInactive,
      pills: [
        const PointyHeroPill(icon: Icons.smartphone_outlined, label: 'SMS Gate'),
        if (gateway != null && gateway.lastError.isNotEmpty)
          PointyHeroPill(
            icon: Icons.error_outline,
            label: l10n.messagingHasRecentError,
          ),
      ],
    );
  }

  Widget _buildConnectionSection(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final gateway = viewModel.gateway;
    return PointyDetailSection(
      icon: Icons.settings_ethernet_outlined,
      title: l10n.messagingConnectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            textDirection: TextDirection.ltr,
            onChanged: viewModel.setBaseUrl,
            decoration: InputDecoration(
              labelText: l10n.messagingBaseUrlLabel,
              hintText: 'http://192.168.1.50:8080',
              prefixIcon: const Icon(Icons.link_outlined),
            ),
          ),
          SizedBox(height: spacing.md),
          TextField(
            controller: _username,
            textDirection: TextDirection.ltr,
            onChanged: viewModel.setUsername,
            decoration: InputDecoration(
              labelText: l10n.messagingUsernameLabel,
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          SizedBox(height: spacing.md),
          TextField(
            controller: _password,
            obscureText: true,
            textDirection: TextDirection.ltr,
            onChanged: viewModel.setPassword,
            decoration: InputDecoration(
              labelText: l10n.messagingPasswordLabel,
              helperText: (gateway?.hasPassword ?? false)
                  ? l10n.messagingPasswordKeepHint
                  : null,
              prefixIcon: const Icon(Icons.key_outlined),
            ),
          ),
          SizedBox(height: spacing.md),
          Row(
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
                    prefixIcon: const Icon(Icons.today_outlined),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.lg),
          FilledButton.icon(
            onPressed: viewModel.canSave ? _save : null,
            icon: viewModel.isSaving
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(l10n.messagingSaveButton),
          ),
          SizedBox(height: spacing.sm),
          OutlinedButton.icon(
            onPressed: viewModel.canActivate ? _activate : null,
            icon: viewModel.isActivating
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_outlined),
            label: Text(l10n.messagingActivateButton),
          ),
          Padding(
            padding: EdgeInsets.only(top: spacing.xs),
            child: Text(
              l10n.messagingActivateHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTestSection(
    BuildContext context,
    AppLocalizations l10n,
    MessagingSettingsViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final canTest =
        viewModel.canTest && _testPhone.text.trim().isNotEmpty;
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
            TextField(
              controller: _testPhone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l10n.messagingTestPhoneLabel,
                hintText: '+2189…',
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
