import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/ai_chat.dart';
import '../../../data/models/relay_installation_status.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/subscription_status_view_model.dart';

/// Shop Settings sub-page surfacing the relay installation ID (so owners can
/// send it to support) alongside the remote-access and AI subscription state —
/// including how much AI usage is left. Read-only; the relay owns the truth.
class SubscriptionStatusPage extends StatefulWidget {
  const SubscriptionStatusPage({super.key, required this.viewModel});

  final SubscriptionStatusViewModel viewModel;

  @override
  State<SubscriptionStatusPage> createState() => _SubscriptionStatusPageState();
}

class _SubscriptionStatusPageState extends State<SubscriptionStatusPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.load());
    });
  }

  Future<void> _sync() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final ok = await widget.viewModel.sync();
    if (!mounted) {
      return;
    }
    if (!ok && widget.viewModel.lastSyncFailed) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.subscriptionSyncFailedMessage)),
      );
    } else if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.subscriptionSyncedMessage)),
      );
    }
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
            title: Text(l10n.subscriptionSectionTitle),
            isLoading: viewModel.isBusy,
            actions: [
              IconButton(
                tooltip: l10n.subscriptionRefreshTooltip,
                onPressed: viewModel.isBusy ? null : _sync,
                icon: viewModel.isSyncing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: PointySpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
              ),
            ],
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;

    if (viewModel.isLoading && viewModel.status == null) {
      return const PointyLoadingArea();
    }

    final status = viewModel.status;
    if (status == null) {
      return PointyErrorState(
        title: l10n.subscriptionStatusLoadError,
        icon: Icons.workspace_premium_outlined,
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
          AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHero(context, l10n, status),
                SizedBox(height: spacing.md),
                _InstallationIdSection(status: status),
                SizedBox(height: spacing.md),
                _RemoteAccessSection(status: status),
                SizedBox(height: spacing.md),
                _AiSection(status: status, usage: viewModel.usage),
                if (status.lastSyncedAt != null) ...[
                  SizedBox(height: spacing.md),
                  Text(
                    l10n.subscriptionLastSynced(
                      formatDateTime(status.lastSyncedAt!),
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.pointyColors.mutedInk,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(
    BuildContext context,
    AppLocalizations l10n,
    RelayInstallationStatus status,
  ) {
    final title = status.shopName.trim().isNotEmpty
        ? status.shopName.trim()
        : l10n.subscriptionHeroFallbackTitle;
    final endsAt = status.subscriptionEndsAt;
    final valueSubtitle = (status.subscriptionActive && !status.subscriptionExpired)
        ? (endsAt != null ? l10n.subscriptionUntilDate(formatDate(endsAt)) : null)
        : null;

    return PointyDetailHero(
      icon: Icons.workspace_premium_outlined,
      title: title,
      value: _subscriptionStatusLabel(l10n, status),
      valueSubtitle: valueSubtitle,
      pills: [
        PointyHeroPill(
          icon: status.remoteAccessSupported
              ? Icons.lan_outlined
              : Icons.cloud_off_outlined,
          label: l10n.subscriptionRemoteAccessPill(
            status.remoteAccessSupported
                ? l10n.subscriptionStateOn
                : l10n.subscriptionStateOff,
          ),
        ),
        PointyHeroPill(
          icon: Icons.auto_awesome_outlined,
          label: l10n.subscriptionAiPill(
            status.aiAvailable
                ? l10n.subscriptionStateOn
                : l10n.subscriptionStateOff,
          ),
        ),
      ],
    );
  }
}

String _subscriptionStatusLabel(
  AppLocalizations l10n,
  RelayInstallationStatus status,
) {
  if (!status.configured) {
    return l10n.subscriptionStatusInactive;
  }
  if (status.subscriptionActive && !status.subscriptionExpired) {
    return l10n.subscriptionStatusActive;
  }
  if (status.subscriptionExpired) {
    return l10n.subscriptionStatusExpired;
  }
  return l10n.subscriptionStatusInactive;
}

/// The installation ID block: a copyable, LTR-isolated identifier plus a one-
/// line explanation of what to do with it. Falls back to a "not linked yet"
/// callout when the shop has never been provisioned on the relay.
class _InstallationIdSection extends StatelessWidget {
  const _InstallationIdSection({required this.status});

  final RelayInstallationStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return PointyDetailSection(
      icon: Icons.fingerprint,
      title: l10n.subscriptionInstallationIdTitle,
      child: status.hasInstallationId
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CopyableInstallationId(installationId: status.installationId),
                SizedBox(height: spacing.sm),
                Text(
                  l10n.subscriptionInstallationIdHelper,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            )
          : PointyDetailCallout(
              icon: Icons.cloud_off_outlined,
              tone: PointyCalloutTone.neutral,
              title: l10n.subscriptionNotConfiguredTitle,
              message: l10n.subscriptionNotConfiguredMessage,
            ),
    );
  }
}

class _CopyableInstallationId extends StatelessWidget {
  const _CopyableInstallationId({required this.installationId});

  final String installationId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    Future<void> copy() async {
      final messenger = ScaffoldMessenger.of(context);
      await Clipboard.setData(ClipboardData(text: installationId));
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.subscriptionInstallationIdCopied)),
      );
    }

    return Material(
      color: colors.surfaceSunken,
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      child: InkWell(
        onTap: copy,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PointyRadii.chip),
            border: Border.all(color: colors.line),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  installationId,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.left,
                  style: PointyTypography.numeric(
                    (textTheme.titleMedium ?? const TextStyle()).copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.ink,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
              SizedBox(width: spacing.sm),
              TextButton.icon(
                onPressed: copy,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: Text(l10n.subscriptionInstallationIdCopy),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Remote-access state: a plain-language callout plus a ledger of the subscription
/// facts (active, expiry, days left, last connector check-in).
class _RemoteAccessSection extends StatelessWidget {
  const _RemoteAccessSection({required this.status});

  final RelayInstallationStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final supported = status.remoteAccessSupported;
    final endsAt = status.subscriptionEndsAt;

    final rows = <PointySummaryRow>[
      PointySummaryRow(
        label: l10n.subscriptionFieldStatus,
        value: supported ? l10n.subscriptionStateOn : l10n.subscriptionStateOff,
        valueColor: supported ? colors.success : colors.mutedInk,
      ),
      PointySummaryRow(
        label: l10n.subscriptionFieldSubscription,
        value: _subscriptionStatusLabel(l10n, status),
        valueColor: status.subscriptionExpired ? colors.danger : null,
      ),
      PointySummaryRow(
        label: l10n.subscriptionFieldExpiresOn,
        value: endsAt != null
            ? formatDate(endsAt)
            : (status.subscriptionActive
                  ? l10n.subscriptionExpiryNever
                  : '—'),
      ),
      if (endsAt != null)
        PointySummaryRow(
          label: l10n.subscriptionFieldRemaining,
          value: status.subscriptionExpired
              ? l10n.subscriptionStatusExpired
              : l10n.subscriptionDaysLeft(status.daysUntilExpiry ?? 0),
          valueColor: status.subscriptionExpired ? colors.danger : null,
        ),
      PointySummaryRow(
        label: l10n.subscriptionFieldLastConnected,
        value: status.connectorLastSeenAt != null
            ? formatDateTime(status.connectorLastSeenAt!)
            : l10n.subscriptionNeverConnected,
      ),
    ];

    return PointyDetailSection(
      icon: Icons.lan_outlined,
      title: l10n.subscriptionRemoteAccessTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyDetailCallout(
            icon: supported ? Icons.verified_user_outlined : Icons.lock_outlined,
            tone: supported
                ? PointyCalloutTone.success
                : PointyCalloutTone.neutral,
            title: supported
                ? l10n.subscriptionRemoteAccessActiveTitle
                : l10n.subscriptionRemoteAccessInactiveTitle,
            message: supported
                ? l10n.subscriptionRemoteAccessActiveMessage
                : l10n.subscriptionRemoteAccessInactiveMessage,
          ),
          SizedBox(height: spacing.md),
          PointySummaryList(rows: rows),
        ],
      ),
    );
  }
}

/// AI-assistant state: entitlement callout and, when entitled, the 5h + weekly
/// usage bars (mirrors the in-chat usage sheet) so owners see how much is left.
class _AiSection extends StatelessWidget {
  const _AiSection({required this.status, required this.usage});

  final RelayInstallationStatus status;
  final AiUsage? usage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final available = status.aiAvailable;
    final snapshot = usage;

    return PointyDetailSection(
      icon: Icons.auto_awesome_outlined,
      title: l10n.subscriptionAiTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyDetailCallout(
            icon: available
                ? Icons.auto_awesome_outlined
                : Icons.lock_outlined,
            tone: available
                ? PointyCalloutTone.success
                : PointyCalloutTone.neutral,
            title: available
                ? l10n.subscriptionAiActiveTitle
                : l10n.subscriptionAiInactiveTitle,
            message: available
                ? l10n.subscriptionAiActiveMessage
                : l10n.subscriptionAiInactiveMessage,
          ),
          if (available) ...[
            SizedBox(height: spacing.md),
            if (snapshot != null) ...[
              _UsageBar(
                label: l10n.aiAssistantUsageFiveHour,
                window: snapshot.fiveHour,
              ),
              SizedBox(height: spacing.md),
              _UsageBar(
                label: l10n.aiAssistantUsageWeekly,
                window: snapshot.weekly,
              ),
            ] else
              Text(
                l10n.subscriptionAiUsageUnavailable,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// One AI usage window as a labelled progress bar — used/limit, a coloured fill
/// that warns as it fills, and a reset hint once exhausted. Mirrors the in-chat
/// usage sheet so the two surfaces read identically.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.label, required this.window});

  final String label;
  final AiUsageWindow window;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final unlimited = window.unlimited;
    final exhausted = !unlimited && window.remaining <= 0;
    final color = exhausted
        ? colors.danger
        : (window.fraction >= 0.8 ? colors.warning : colors.primary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              unlimited
                  ? l10n.aiAssistantUsageUnlimited
                  : l10n.aiAssistantUsageUsedOfLimit(window.used, window.limit),
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
        SizedBox(height: spacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: PointyProgressBar(
            value: unlimited ? 0 : window.fraction.clamp(0.0, 1.0).toDouble(),
            minHeight: 7,
            backgroundColor: colors.line,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        if (!unlimited) ...[
          SizedBox(height: spacing.xs),
          Text(
            exhausted && window.resetAt != null
                ? l10n.aiAssistantUsageResets(formatDateTime(window.resetAt!))
                : l10n.aiAssistantUsageRemaining(window.remaining),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ],
    );
  }
}
