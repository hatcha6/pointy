import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/campaign.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/campaigns_view_model.dart';

/// Curated RFM targeting options offered as chips (slug + Arabic label).
const List<(String, String)> _rfmOptions = [
  ('champion', 'الأبطال'),
  ('loyal', 'الأوفياء'),
  ('potential_loyalist', 'واعدون'),
  ('new_customer', 'عملاء جدد'),
  ('promising', 'مبشّرون'),
  ('needs_attention', 'يحتاجون اهتمامًا'),
  ('at_risk', 'في خطر'),
  ('cant_lose', 'لا نخسرهم'),
  ('hibernating', 'خاملون'),
  ('lost', 'مفقودون'),
];

int estimateSegments(String text) {
  if (text.isEmpty) return 1;
  final unicode = text.runes.any((rune) => rune > 127);
  final perSegment = unicode ? 70 : 160;
  return (text.length / perSegment).ceil().clamp(1, 999);
}

(String, Color) _statusChip(
  BuildContext context,
  AppLocalizations l10n,
  CampaignStatus status,
) {
  final colors = context.pointyColors;
  return switch (status) {
    CampaignStatus.sent => (l10n.campaignStatusSent, colors.success),
    CampaignStatus.sending ||
    CampaignStatus.approved => (l10n.campaignStatusSending, colors.primary),
    CampaignStatus.failed => (l10n.campaignStatusFailed, colors.danger),
    CampaignStatus.cancelled => (l10n.campaignStatusCancelled, colors.mutedInk),
    _ => (l10n.campaignStatusDraft, colors.mutedInk),
  };
}

/// Top-level Campaigns screen: the list of marketing campaigns.
class CampaignsScreen extends StatefulWidget {
  const CampaignsScreen({
    super.key,
    required this.viewModel,
    required this.navigation,
    required this.capabilities,
  });

  final CampaignsViewModel viewModel;
  final AppNavigation navigation;
  final AuthorizationCapabilities capabilities;

  @override
  State<CampaignsScreen> createState() => _CampaignsScreenState();
}

class _CampaignsScreenState extends State<CampaignsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.viewModel.load());
    });
  }

  Future<void> _openEditor(Campaign? campaign) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CampaignEditorScreen(
          viewModel: widget.viewModel.editorFor(campaign),
          canSend: widget.capabilities.canSendCampaigns,
        ),
      ),
    );
    if (mounted) unawaited(widget.viewModel.load());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.campaigns,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.campaignsTitle),
            isLoading: widget.viewModel.isLoading,
            actions: [
              IconButton(
                tooltip: l10n.retryButton,
                onPressed: widget.viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: widget.capabilities.canManageCampaigns
              ? FloatingActionButton.extended(
                  onPressed: () => _openEditor(null),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.campaignNewButton),
                )
              : null,
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    if (viewModel.isLoading && viewModel.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.isEmpty) {
      return PointyErrorState(
        title: l10n.campaignsLoadError,
        icon: Icons.campaign_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final spacing = AdaptiveSpacing.of(context);
    return RefreshIndicator(
      onRefresh: viewModel.load,
      child: ListView(
        padding: spacing.pagePadding,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (viewModel.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: spacing.xl),
              child: PointyEmptyState(
                icon: Icons.campaign_outlined,
                title: l10n.campaignsEmpty,
              ),
            )
          else
            for (final campaign in viewModel.campaigns)
              _CampaignTile(
                campaign: campaign,
                onTap: () => _openEditor(campaign),
              ),
        ],
      ),
    );
  }
}

class _CampaignTile extends StatelessWidget {
  const _CampaignTile({required this.campaign, required this.onTap});

  final Campaign campaign;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (label, color) = _statusChip(context, l10n, campaign.status);
    return PointyDataRow(
      leading: const CircleAvatar(child: Icon(Icons.campaign_outlined)),
      title: campaign.name,
      subtitle: l10n.campaignRecipientsSummary(
        campaign.sentCount,
        campaign.totalRecipients,
      ),
      badges: [
        PointyStatusPill(label: label, color: color),
        if (campaign.isFromAi)
          PointyStatusPill(
            label: l10n.campaignAiBadge,
            icon: Icons.auto_awesome_outlined,
          ),
      ],
      onTap: onTap,
    );
  }
}

/// Create/edit a draft campaign, preview the audience, and approve+send.
class CampaignEditorScreen extends StatefulWidget {
  const CampaignEditorScreen({
    super.key,
    required this.viewModel,
    required this.canSend,
  });

  final CampaignEditorViewModel viewModel;
  final bool canSend;

  @override
  State<CampaignEditorScreen> createState() => _CampaignEditorScreenState();
}

class _CampaignEditorScreenState extends State<CampaignEditorScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.viewModel.name);
  late final TextEditingController _body =
      TextEditingController(text: widget.viewModel.bodyTemplate);

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await widget.viewModel.save();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.campaignSavedMessage : l10n.campaignSaveError),
      ),
    );
  }

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (!await _confirmSend(l10n)) return;
    final ok = await widget.viewModel.send();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.campaignSentMessage : l10n.campaignSendError),
      ),
    );
    if (ok) navigator.pop();
  }

  /// Sending is irreversible — the messages leave immediately and cannot be
  /// recalled — so the recipient count is put in front of the manager first.
  Future<bool> _confirmSend(AppLocalizations l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        key: const ValueKey('campaign_send_confirm_dialog'),
        title: l10n.campaignSendConfirmTitle,
        message: l10n.campaignSendConfirmMessage(
          widget.viewModel.preview?.sendableEstimate ?? 0,
        ),
        confirmLabel: l10n.campaignSendConfirmButton,
      ),
    );
    return confirmed == true && mounted;
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
            title: Text(
              viewModel.isNew ? l10n.campaignNewTitle : l10n.campaignEditTitle,
            ),
            isLoading: viewModel.isBusy,
          ),
          body: viewModel.isDraft
              ? _buildEditor(context, l10n, viewModel)
              : _buildReadOnly(context, l10n, viewModel),
        );
      },
    );
  }

  Widget _buildReadOnly(
    BuildContext context,
    AppLocalizations l10n,
    CampaignEditorViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final campaign = viewModel.campaign!;
    final (label, _) = _statusChip(context, l10n, campaign.status);
    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.campaign_outlined,
            title: campaign.name,
            child: PointySummaryList(
              rows: [
                PointySummaryRow(label: l10n.campaignStatusLabel, value: label),
                PointySummaryRow(
                  label: l10n.campaignPreviewSendable,
                  value: '${campaign.sentCount}',
                ),
                PointySummaryRow(
                  label: l10n.campaignPreviewSkipped,
                  value: '${campaign.skippedOptoutCount}',
                ),
                PointySummaryRow(
                  label: l10n.campaignPreviewAudience,
                  value: '${campaign.totalRecipients}',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditor(
    BuildContext context,
    AppLocalizations l10n,
    CampaignEditorViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointyDetailSection(
                icon: Icons.edit_outlined,
                title: l10n.campaignNewTitle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _name,
                      onChanged: viewModel.setName,
                      decoration: InputDecoration(
                        labelText: l10n.campaignNameLabel,
                        prefixIcon: const Icon(Icons.title_outlined),
                      ),
                    ),
                    SizedBox(height: spacing.md),
                    TextField(
                      controller: _body,
                      onChanged: viewModel.setBodyTemplate,
                      minLines: 3,
                      maxLines: 6,
                      inputFormatters: const [],
                      decoration: InputDecoration(
                        labelText: l10n.campaignBodyLabel,
                        helperText: l10n.campaignBodyHelp,
                        helperMaxLines: 2,
                        alignLabelWithHint: true,
                      ),
                    ),
                    SizedBox(height: spacing.xs),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        l10n.campaignSegmentsCounter(
                          estimateSegments(_body.text),
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.pointyColors.mutedInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                icon: Icons.groups_outlined,
                title: l10n.campaignAudienceTitle,
                child: Wrap(
                  spacing: spacing.sm,
                  runSpacing: spacing.sm,
                  children: [
                    for (final (slug, label) in _rfmOptions)
                      FilterChip(
                        label: Text(label),
                        selected: viewModel.rfmSegments.contains(slug),
                        onSelected: viewModel.isBusy
                            ? null
                            : (_) => viewModel.toggleSegment(slug),
                      ),
                  ],
                ),
              ),
              SizedBox(height: spacing.lg),
              FilledButton.icon(
                onPressed: viewModel.canSave ? _save : null,
                icon: viewModel.isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(l10n.campaignSaveButton),
              ),
              SizedBox(height: spacing.md),
              _buildApproval(context, l10n, viewModel),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildApproval(
    BuildContext context,
    AppLocalizations l10n,
    CampaignEditorViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    if (viewModel.isNew) {
      return PointyDetailCallout(
        icon: Icons.info_outline,
        tone: PointyCalloutTone.neutral,
        title: l10n.campaignSaveFirstTitle,
        message: l10n.campaignSaveFirstHint,
      );
    }

    final preview = viewModel.preview;
    return PointyDetailSection(
      icon: Icons.send_outlined,
      title: l10n.campaignPreviewTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: viewModel.isBusy ? null : viewModel.loadPreview,
            icon: viewModel.isPreviewing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.query_stats_outlined),
            label: Text(l10n.campaignPreviewButton),
          ),
          if (preview != null) ...[
            SizedBox(height: spacing.md),
            PointySummaryList(
              rows: [
                PointySummaryRow(
                  label: l10n.campaignPreviewAudience,
                  value: '${preview.audienceTotal}',
                ),
                PointySummaryRow(
                  label: l10n.campaignPreviewSendable,
                  value: '${preview.sendableEstimate}',
                  valueColor: context.pointyColors.success,
                ),
                PointySummaryRow(
                  label: l10n.campaignPreviewSkipped,
                  value: '${preview.skippedEstimate}',
                ),
                PointySummaryRow(
                  label: l10n.campaignPreviewSegments,
                  value: '${preview.segments}',
                ),
                PointySummaryRow(
                  label: l10n.campaignPreviewDurationLabel,
                  value: l10n.campaignPreviewDuration(preview.estimatedMinutes),
                ),
              ],
            ),
            SizedBox(height: spacing.sm),
            PointyDetailCallout(
              icon: Icons.sms_outlined,
              tone: PointyCalloutTone.neutral,
              title: l10n.campaignSampleTitle,
              message: preview.sampleMessage,
            ),
            SizedBox(height: spacing.md),
            if (widget.canSend)
              FilledButton.icon(
                onPressed: viewModel.canSend ? _send : null,
                icon: viewModel.isSending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: Text(l10n.campaignSendButton),
              )
            else
              Text(
                l10n.campaignNoSendPermission,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.pointyColors.mutedInk,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
