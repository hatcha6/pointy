import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/parsing.dart';
import '../../../data/models/fraud_finding.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrity_monitor_view_model.dart';

/// The integrity monitor: the always-on fraud engine's face. Quiet when all
/// is well, decisive when something needs the owner — every finding carries
/// its evidence and a one-tap verdict.
class IntegrityMonitorScreen extends StatelessWidget {
  const IntegrityMonitorScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    this.onOpenActivityLog,
  });

  final IntegrityMonitorViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onOpenActivityLog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.integrityMonitorTitle),
            actions: [
              IconButton(
                tooltip: l10n.integrityMonitorRefreshTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.loadFindings,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          backgroundColor: colors.page,
          body: _IntegrityBody(
            viewModel: viewModel,
            capabilities: capabilities,
            onOpenActivityLog: onOpenActivityLog,
          ),
        );
      },
    );
  }
}

class _IntegrityBody extends StatelessWidget {
  const _IntegrityBody({
    required this.viewModel,
    required this.capabilities,
    required this.onOpenActivityLog,
  });

  final IntegrityMonitorViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onOpenActivityLog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.findings.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasError && viewModel.findings.isEmpty) {
      return PointyErrorState(
        icon: Icons.gpp_maybe_outlined,
        title: l10n.integrityMonitorLoadError,
        action: FilledButton.icon(
          onPressed: viewModel.loadFindings,
          icon: const Icon(Icons.sync),
          label: Text(l10n.integrityMonitorRefreshTooltip),
        ),
      );
    }

    final active = viewModel.activeFindings;
    final settled = viewModel.settledFindings;

    return RefreshIndicator(
      onRefresh: viewModel.loadFindings,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: spacing.pagePadding,
        child: AdaptiveMaxWidth(
          width: AppContentWidth.workspace,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _MonitorStatusCard(activeCount: active.length),
              if (viewModel.hasSaveError) ...[
                SizedBox(height: spacing.sm),
                PointyInlineMessage.error(
                  message: l10n.integrityMonitorActionError,
                  icon: Icons.warning_amber_outlined,
                ),
              ],
              if (active.isNotEmpty) ...[
                SizedBox(height: spacing.lg),
                PointySectionHeader(
                  title: l10n.integrityMonitorActiveSection,
                  leading: const Icon(Icons.notifications_active_outlined),
                ),
                SizedBox(height: spacing.sm),
                for (final finding in active) ...[
                  _FindingCard(
                    finding: finding,
                    viewModel: viewModel,
                    capabilities: capabilities,
                    onOpenActivityLog: onOpenActivityLog,
                  ),
                  SizedBox(height: spacing.sm),
                ],
              ],
              if (settled.isNotEmpty) ...[
                SizedBox(height: spacing.lg),
                PointySectionHeader(
                  title: l10n.integrityMonitorSettledSection,
                  leading: const Icon(Icons.history_outlined),
                ),
                SizedBox(height: spacing.sm),
                for (final finding in settled.take(10)) ...[
                  _FindingCard(
                    finding: finding,
                    viewModel: viewModel,
                    capabilities: capabilities,
                    onOpenActivityLog: onOpenActivityLog,
                  ),
                  SizedBox(height: spacing.sm),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MonitorStatusCard extends StatelessWidget {
  const _MonitorStatusCard({required this.activeCount});

  final int activeCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final allClear = activeCount == 0;
    final accent = allClear ? colors.success : colors.warning;

    return Card(
      key: const ValueKey('integrity_status_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: spacing.sectionPadding,
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.alphaBlend(
                  accent.withValues(alpha: 0.12),
                  colors.surface,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Icon(
                  allClear
                      ? Icons.verified_user_outlined
                      : Icons.gpp_maybe_outlined,
                  color: accent,
                  size: 34,
                ),
              ),
            ),
            SizedBox(width: spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    allClear
                        ? l10n.integrityMonitorAllClearTitle
                        : l10n.integrityMonitorAttentionTitle(activeCount),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: allClear ? colors.success : colors.ink,
                    ),
                  ),
                  SizedBox(height: spacing.xs),
                  Text(
                    l10n.integrityMonitorSubtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({
    required this.finding,
    required this.viewModel,
    required this.capabilities,
    required this.onOpenActivityLog,
  });

  final FraudFinding finding;
  final IntegrityMonitorViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onOpenActivityLog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final severityColor = _severityColor(context, finding.severity);
    final isActive = finding.status == FraudFindingStatus.active;

    return Card(
      key: ValueKey('fraud_finding_card_${finding.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetails(context),
        child: Padding(
          padding: spacing.compactPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _RiskBadge(score: finding.riskScore, color: severityColor),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          finding.displayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: spacing.xs),
                        Text(
                          finding.headline.isNotEmpty
                              ? finding.headline
                              : finding.ruleTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  PointyStatusPill(
                    label: _statusLabel(l10n, finding.status),
                    color: isActive ? severityColor : colors.mutedInk,
                    icon: isActive
                        ? Icons.notifications_active_outlined
                        : Icons.task_alt_outlined,
                  ),
                ],
              ),
              SizedBox(height: spacing.sm),
              Wrap(
                spacing: spacing.xs,
                runSpacing: spacing.xs,
                children: [
                  if (finding.ruleTitle.isNotEmpty)
                    PointyStatusPill(
                      label: finding.ruleTitle,
                      icon: Icons.rule_outlined,
                    ),
                  if (_amountValue(finding.amount) > 0)
                    PointyStatusPill(
                      label: formatMoney(_amountValue(finding.amount)),
                      icon: Icons.payments_outlined,
                      color: severityColor,
                    ),
                  if (finding.lastDetectedAt != null)
                    PointyStatusPill(
                      label: formatDateTime(finding.lastDetectedAt!),
                      icon: Icons.schedule_outlined,
                    ),
                ],
              ),
              if (finding.resolutionNote.trim().isNotEmpty) ...[
                SizedBox(height: spacing.xs),
                Text(
                  l10n.integrityFindingNoteLabel(
                    finding.reviewedByUsername,
                    finding.resolutionNote.trim(),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDetails(BuildContext context) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      builder: (sheetContext) => _FindingDetailsSheet(
        finding: finding,
        viewModel: viewModel,
        capabilities: capabilities,
        onOpenActivityLog: onOpenActivityLog,
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.score, required this.color});

  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 3),
      ),
      child: SizedBox.square(
        dimension: 52,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$score',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            Text(
              l10n.integrityRiskScoreCaption,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 8,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FindingDetailsSheet extends StatefulWidget {
  const _FindingDetailsSheet({
    required this.finding,
    required this.viewModel,
    required this.capabilities,
    required this.onOpenActivityLog,
  });

  final FraudFinding finding;
  final IntegrityMonitorViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onOpenActivityLog;

  @override
  State<_FindingDetailsSheet> createState() => _FindingDetailsSheetState();
}

class _FindingDetailsSheetState extends State<_FindingDetailsSheet> {
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final finding = widget.finding;
    final canManage = widget.capabilities.canManageFraudFindings;
    final isActive = finding.status == FraudFindingStatus.active;
    final evidenceRows = _evidenceRows(finding);
    final comparisons = _peerComparisons(l10n, finding);

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.sheet),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PointySectionHeader(
              title: finding.displayLabel,
              subtitle: finding.headline.isNotEmpty
                  ? finding.headline
                  : finding.ruleTitle,
              leading: const Icon(Icons.gpp_maybe_outlined),
              trailing: _RiskBadge(
                score: finding.riskScore,
                color: _severityColor(context, finding.severity),
              ),
            ),
            Divider(height: 1, color: colors.line),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsetsDirectional.only(
                  start: spacing.lg,
                  end: spacing.lg,
                  top: spacing.md,
                  bottom: spacing.lg + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PointyMetricGrid(
                      maxColumns: 2,
                      minTileWidth: 180,
                      gap: PointyMetricGridGap.compact,
                      metrics: [
                        if (finding.windowStart != null &&
                            finding.windowEnd != null)
                          PointyMetricGridItem(
                            label: l10n.integrityFindingWindowLabel,
                            value: l10n.payrollPeriodSubtitle(
                              formatDate(finding.windowStart!),
                              formatDate(finding.windowEnd!),
                            ),
                            icon: Icons.date_range_outlined,
                          ),
                        PointyMetricGridItem(
                          label: l10n.integrityFindingPatternCountLabel,
                          value: '${finding.patternCount}',
                          icon: Icons.event_repeat_outlined,
                        ),
                      ],
                    ),
                    if (comparisons.isNotEmpty) ...[
                      SizedBox(height: spacing.md),
                      PointyDetailSection(
                        title: l10n.integrityPeerComparisonTitle,
                        icon: Icons.groups_outlined,
                        child: PointySummaryList(
                          rows: [
                            for (final row in comparisons)
                              PointySummaryRow(label: row.$1, value: row.$2),
                          ],
                        ),
                      ),
                    ],
                    if (evidenceRows.isNotEmpty) ...[
                      SizedBox(height: spacing.md),
                      PointyDetailSection(
                        title: l10n.integrityEvidenceTitle,
                        icon: Icons.receipt_long_outlined,
                        child: PointySummaryList(
                          rows: [
                            for (final row in evidenceRows.take(10))
                              PointySummaryRow(label: row.$1, value: row.$2),
                          ],
                        ),
                      ),
                    ],
                    if (widget.onOpenActivityLog != null) ...[
                      SizedBox(height: spacing.md),
                      OutlinedButton.icon(
                        key: const ValueKey(
                          'integrity_open_activity_log_button',
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onOpenActivityLog!();
                        },
                        icon: const Icon(Icons.manage_search_outlined),
                        label: Text(l10n.integrityOpenActivityLogButton),
                      ),
                    ],
                    if (canManage && isActive) ...[
                      SizedBox(height: spacing.md),
                      TextField(
                        key: const ValueKey('integrity_note_field'),
                        controller: _noteController,
                        enabled: !widget.viewModel.isSaving,
                        decoration: InputDecoration(
                          labelText: l10n.integrityNoteFieldLabel,
                          helperText: l10n.integrityNoteFieldHelper,
                        ),
                        minLines: 2,
                        maxLines: 4,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (canManage)
              PointyStickyActionFooter(
                secondaryActions: [
                  if (isActive)
                    TextButton.icon(
                      key: const ValueKey('integrity_dismiss_button'),
                      onPressed: widget.viewModel.isSaving
                          ? null
                          : () => _act(
                              () => widget.viewModel.dismissFinding(
                                widget.finding,
                                note: _noteController.text,
                              ),
                            ),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.danger,
                      ),
                      icon: const Icon(Icons.block_outlined),
                      label: Text(l10n.integrityDismissButton),
                    ),
                ],
                primaryAction: isActive
                    ? FilledButton.icon(
                        key: const ValueKey('integrity_review_button'),
                        onPressed: widget.viewModel.isSaving
                            ? null
                            : () => _act(
                                () => widget.viewModel.reviewFinding(
                                  widget.finding,
                                  note: _noteController.text,
                                ),
                              ),
                        icon: const Icon(Icons.verified_outlined),
                        label: Text(l10n.integrityReviewButton),
                      )
                    : FilledButton.tonalIcon(
                        key: const ValueKey('integrity_reopen_button'),
                        onPressed: widget.viewModel.isSaving
                            ? null
                            : () => _act(
                                () => widget.viewModel.reopenFinding(
                                  widget.finding,
                                ),
                              ),
                        icon: const Icon(Icons.replay_outlined),
                        label: Text(l10n.integrityReopenButton),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _act(Future<bool> Function() action) async {
    final saved = await action();
    if (saved && mounted) {
      Navigator.of(context).pop();
    }
  }
}

List<(String, String)> _evidenceRows(FraudFinding finding) {
  final rows = <(String, String)>[];
  for (final entry in finding.evidence.entries) {
    final value = entry.value;
    if (value is! List) {
      continue;
    }
    for (final item in value) {
      if (item is! Map) {
        continue;
      }
      final map = item.map((key, value) => MapEntry(key.toString(), value));
      final label = [
        if (map['receipt_number'] != null) map['receipt_number'].toString(),
        if (map['session_number'] != null) map['session_number'].toString(),
        if (map['reason'] != null && map['reason'].toString().trim().isNotEmpty)
          map['reason'].toString().trim(),
        if (map['occurred_at'] != null)
          _shortDate(map['occurred_at'].toString()),
        if (map['created_at'] != null) _shortDate(map['created_at'].toString()),
      ].join(' · ');
      final amount = map['amount'] ?? map['cash_variance'] ?? map['total'];
      rows.add((
        label.isEmpty ? '—' : label,
        amount == null ? '' : formatMoney(_amountValue(amount.toString())),
      ));
    }
  }
  return rows;
}

List<(String, String)> _peerComparisons(
  AppLocalizations l10n,
  FraudFinding finding,
) {
  final peer = finding.peerMetrics;
  if (peer.isEmpty) {
    return const [];
  }
  final rows = <(String, String)>[];
  final rate = peer['rate'] ?? peer['user_rate'];
  final median = peer['median'];
  final threshold = peer['threshold'];
  if (rate != null) {
    rows.add((l10n.integrityUserRateLabel, _percentString(rate)));
  }
  if (median != null) {
    rows.add((l10n.integrityPeerMedianLabel, _percentString(median)));
  }
  if (threshold != null) {
    rows.add((l10n.integrityThresholdLabel, _percentString(threshold)));
  }
  return rows;
}

String _percentString(Object? value) {
  final number = double.tryParse(value?.toString() ?? '');
  if (number == null) {
    return value?.toString() ?? '-';
  }
  return '${(number * 100).toStringAsFixed(1)}%';
}

String _shortDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value;
  }
  return formatDate(parsed);
}

double _amountValue(String value) {
  return parseDecimalOr(value);
}

Color _severityColor(BuildContext context, FraudFindingSeverity severity) {
  final colors = context.pointyColors;
  return switch (severity) {
    FraudFindingSeverity.critical => colors.danger,
    FraudFindingSeverity.warning => colors.warning,
    FraudFindingSeverity.info => colors.primaryStrong,
  };
}

String _statusLabel(AppLocalizations l10n, FraudFindingStatus status) {
  return switch (status) {
    FraudFindingStatus.active => l10n.integrityStatusActive,
    FraudFindingStatus.resolved => l10n.integrityStatusResolved,
    FraudFindingStatus.reviewed => l10n.integrityStatusReviewed,
    FraudFindingStatus.dismissed => l10n.integrityStatusDismissed,
  };
}
