import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/activity_log_view_model.dart';
import 'activity_log_event_presenter.dart';
import 'activity_log_query_controls.dart';

class ActivityLogScreen extends StatelessWidget {
  const ActivityLogScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenUsers,
    this.onOpenShopSettings,
    this.onOpenTarget,
  });

  final ActivityLogViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final Future<void> Function(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  )?
  onOpenTarget;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.activityLog,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenUsers: onOpenUsers,
            onOpenActivityLog: () {},
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.activityLogTitle),
            isLoading: viewModel.isLoading,
            reserveLoadingSlot: false,
            actions: [
              ActivityLogGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshActivityLogTooltip,
                  onPressed: viewModel.loadEvents,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: ActivityLogGuard(
            capabilities: capabilities,
            child: _ActivityLogBody(
              viewModel: viewModel,
              onOpenTarget: onOpenTarget,
            ),
          ),
        );
      },
    );
  }
}

class _ActivityLogBody extends StatelessWidget {
  const _ActivityLogBody({required this.viewModel, required this.onOpenTarget});

  final ActivityLogViewModel viewModel;
  final Future<void> Function(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  )?
  onOpenTarget;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ActivityLogQueryControls(
            query: viewModel.query,
            users: viewModel.users,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
            enabled: !viewModel.isLoading,
          ),
          if (viewModel.investigationReason.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.warning(
              message: l10n.activityLogSuspicionReviewBanner(
                viewModel.investigationReason,
              ),
              icon: Icons.manage_search_outlined,
            ),
          ],
          SizedBox(height: spacing.md),
          PointyMetricGrid(
            gap: PointyMetricGridGap.compact,
            minTileWidth: 170,
            maxColumns: 4,
            metrics: [
              PointyMetricGridItem(
                label: l10n.activityLogTotalMetric,
                value: '${viewModel.totalCount}',
                icon: Icons.manage_search_outlined,
              ),
              PointyMetricGridItem(
                label: l10n.activityLogLoadedMetric,
                value: '${viewModel.loadedCount}',
                icon: Icons.view_timeline_outlined,
              ),
              PointyMetricGridItem(
                label: l10n.activityLogFraudMetric,
                value: '${viewModel.loadedFraudSignalCount}',
                icon: Icons.gpp_maybe_outlined,
              ),
              PointyMetricGridItem(
                label: l10n.activityLogHighRiskMetric,
                value: '${viewModel.loadedHighRiskCount}',
                icon: Icons.warning_amber_outlined,
              ),
            ],
          ),
          if (viewModel.hasUserLoadError) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.warning(
              message: l10n.activityLogUsersLoadWarning,
              icon: Icons.person_search_outlined,
            ),
          ],
          if (viewModel.hasLoadError && viewModel.events.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.error(
              message: l10n.activityLogLoadError,
              icon: Icons.warning_amber_outlined,
            ),
          ],
          SizedBox(height: spacing.md),
          Expanded(
            child: _ActivityWorkspace(
              viewModel: viewModel,
              onOpenTarget: onOpenTarget,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityWorkspace extends StatelessWidget {
  const _ActivityWorkspace({
    required this.viewModel,
    required this.onOpenTarget,
  });

  final ActivityLogViewModel viewModel;
  final Future<void> Function(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  )?
  onOpenTarget;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final isCompact = width < 980;
        final timeline = _ActivityTimeline(
          viewModel: viewModel,
          isCompact: isCompact,
          onOpenTarget: onOpenTarget,
        );

        if (isCompact) {
          return timeline;
        }

        return TwoPaneLayout(
          dualPaneBreakpoint: 980,
          primaryPane: _ActivityDetailsPane(
            event: viewModel.selectedEvent,
            onOpenTarget: onOpenTarget,
          ),
          secondaryPane: timeline,
          secondaryFirst: true,
          secondaryPaneWidth: 470,
          compactPrimaryFlex: 1,
          compactSecondaryFlex: 1,
        );
      },
    );
  }
}

class _ActivityTimeline extends StatelessWidget {
  const _ActivityTimeline({
    required this.viewModel,
    required this.isCompact,
    required this.onOpenTarget,
  });

  final ActivityLogViewModel viewModel;
  final bool isCompact;
  final Future<void> Function(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  )?
  onOpenTarget;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDataList<AnalyticsEventRecord>(
      items: viewModel.events,
      onLoadMore: viewModel.loadMoreEvents,
      hasMore: viewModel.hasMoreEvents,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMore,
      hasError: viewModel.hasLoadError,
      errorBuilder: (context) => PointyErrorState(
        title: l10n.activityLogLoadError,
        icon: Icons.warning_amber_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadEvents,
          icon: const Icon(Icons.sync),
          label: Text(l10n.refreshActivityLogTooltip),
        ),
      ),
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.manage_search_outlined,
        title: l10n.activityLogEmpty,
      ),
      padding: EdgeInsets.zero,
      framed: false,
      itemBuilder: (context, event) {
        return _ActivityEventRow(
          event: event,
          selected: viewModel.selectedEvent?.id == event.id,
          onOpenTarget: onOpenTarget,
          onTap: () {
            viewModel.selectEvent(event);
            if (isCompact) {
              _showEventDetails(context, event);
            }
          },
        );
      },
    );
  }

  Future<void> _showEventDetails(
    BuildContext context,
    AnalyticsEventRecord event,
  ) {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.94,
      builder: (context) =>
          _CompactDetailsSheet(event: event, onOpenTarget: onOpenTarget),
    );
  }
}

class _ActivityEventRow extends StatelessWidget {
  const _ActivityEventRow({
    required this.event,
    required this.selected,
    required this.onOpenTarget,
    required this.onTap,
  });

  final AnalyticsEventRecord event;
  final bool selected;
  final Future<void> Function(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  )?
  onOpenTarget;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final userLabel = event.receivedByUsername.trim().isEmpty
        ? l10n.activityLogUnknownUser
        : event.receivedByUsername;
    final sessionReference = event.registerSessionReference;
    final presentation = activityEventPresentation(l10n, event);
    final target = activityLogDrillDownTarget(event);

    return PointyDataRow(
      selected: selected,
      leading: CircleAvatar(child: Icon(presentation.icon, size: 20)),
      title: presentation.title,
      subtitle: presentation.summary.isEmpty
          ? l10n.activityLogEventSubtitle(
              formatDateTime(event.occurredAt),
              userLabel,
            )
          : l10n.activityLogEventSubtitleWithSummary(
              formatDateTime(event.occurredAt),
              userLabel,
              presentation.summary,
            ),
      badges: [
        PointyStatusPill(
          label: analyticsEventTypeLabel(l10n, event.eventType),
          icon: _eventTypeIcon(event.eventType),
        ),
        PointyStatusPill(
          label: analyticsSeverityLabel(l10n, event.severity),
          icon: _eventSeverityIcon(event.severity),
          color: _severityColor(context, event.severity),
        ),
        if (sessionReference.isNotEmpty)
          PointyStatusPill(
            label: sessionReference,
            icon: Icons.point_of_sale_outlined,
          ),
        if (event.hasRiskScore)
          PointyStatusPill(
            label: l10n.activityLogRiskScore(event.riskScore!),
            icon: Icons.shield_outlined,
            color: _riskColor(context, event.riskScore!),
          ),
      ],
      actions: [
        if (target != null && onOpenTarget != null)
          IconButton.filledTonal(
            tooltip: activityLogDrillDownLabel(l10n, target),
            onPressed: () => onOpenTarget!(context, target),
            icon: Icon(activityLogDrillDownIcon(target)),
          ),
      ],
      onTap: onTap,
    );
  }
}

class _CompactDetailsSheet extends StatelessWidget {
  const _CompactDetailsSheet({required this.event, required this.onOpenTarget});

  final AnalyticsEventRecord event;
  final Future<void> Function(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  )?
  onOpenTarget;

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: _ActivityDetailsPane(event: event, onOpenTarget: onOpenTarget),
      ),
    );
  }
}

class _ActivityDetailsPane extends StatelessWidget {
  const _ActivityDetailsPane({required this.event, required this.onOpenTarget});

  final AnalyticsEventRecord? event;
  final Future<void> Function(
    BuildContext context,
    ActivityLogDrillDownTarget target,
  )?
  onOpenTarget;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final event = this.event;

    if (event == null) {
      return PointyEmptyState(
        icon: Icons.fact_check_outlined,
        title: l10n.activityLogNoEventSelected,
      );
    }
    final presentation = activityEventPresentation(l10n, event);
    final target = activityLogDrillDownTarget(event);

    return SingleChildScrollView(
      padding: spacing.compactPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySectionHeader(
            title: presentation.title,
            subtitle: [
              formatDateTime(event.occurredAt),
              if (presentation.summary.isNotEmpty) presentation.summary,
            ].join(' - '),
            leading: Icon(presentation.icon),
          ),
          if (target != null && onOpenTarget != null) ...[
            SizedBox(height: spacing.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: () => onOpenTarget!(context, target),
                icon: Icon(activityLogDrillDownIcon(target)),
                label: Text(activityLogDrillDownLabel(l10n, target)),
              ),
            ),
          ],
          SizedBox(height: spacing.md),
          PointyMetricGrid(
            gap: PointyMetricGridGap.compact,
            minTileWidth: 170,
            maxColumns: 2,
            metrics: [
              PointyMetricGridItem(
                label: l10n.activityLogDetailUser,
                value: event.receivedByUsername.trim().isEmpty
                    ? l10n.activityLogUnknownUser
                    : event.receivedByUsername,
                icon: Icons.person_outline,
              ),
              PointyMetricGridItem(
                label: l10n.activityLogDetailRisk,
                value: event.riskScore == null
                    ? l10n.activityLogNoRiskScore
                    : l10n.activityLogRiskScore(event.riskScore!),
                icon: Icons.shield_outlined,
              ),
            ],
          ),
          SizedBox(height: spacing.md),
          PointyDetailSection(
            title: l10n.activityLogDetailEventSection,
            icon: Icons.fact_check_outlined,
            child: Column(
              children: [
                PointyDetailRow(
                  label: l10n.activityLogRawNameLabel,
                  value: event.name,
                ),
                PointyDetailRow(
                  label: l10n.activityLogTypeLabel,
                  value: analyticsEventTypeLabel(l10n, event.eventType),
                ),
                PointyDetailRow(
                  label: l10n.activityLogSeverityLabel,
                  value: analyticsSeverityLabel(l10n, event.severity),
                ),
                PointyDetailRow(
                  label: l10n.activityLogSourceLabel,
                  value: analyticsSourceLabel(l10n, event.source),
                ),
              ],
            ),
          ),
          SizedBox(height: spacing.md),
          PointyDetailSection(
            title: l10n.activityLogDetailContextSection,
            icon: Icons.hub_outlined,
            child: Column(
              children: [
                PointyDetailRow(
                  label: l10n.activityLogSessionLabel,
                  value: _orEmpty(l10n, event.registerSessionReference),
                ),
                PointyDetailRow(
                  label: l10n.activityLogEntityTypeLabel,
                  value: _orEmpty(l10n, event.entityType),
                ),
                PointyDetailRow(
                  label: l10n.activityLogEntityIdLabel,
                  value: _orEmpty(l10n, event.entityId),
                ),
                PointyDetailRow(
                  label: l10n.activityLogTraceIdLabel,
                  value: _orEmpty(l10n, event.traceId),
                ),
                PointyDetailRow(
                  label: l10n.activityLogPlatformLabel,
                  value: _orEmpty(l10n, event.platform),
                ),
              ],
            ),
          ),
          SizedBox(height: spacing.md),
          PointyDetailSection(
            title: l10n.activityLogAttributesSection,
            icon: Icons.data_object_outlined,
            child: _MapDetails(
              values: event.attributes,
              emptyLabel: l10n.activityLogNoAttributes,
            ),
          ),
          SizedBox(height: spacing.md),
          PointyDetailSection(
            title: l10n.activityLogMetricsSection,
            icon: Icons.query_stats_outlined,
            child: _MapDetails(
              values: event.metrics,
              emptyLabel: l10n.activityLogNoMetrics,
            ),
          ),
        ],
      ),
    );
  }
}

class _MapDetails extends StatelessWidget {
  const _MapDetails({required this.values, required this.emptyLabel});

  final Map<String, Object?> values;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return Text(emptyLabel);
    }

    final entries = values.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return Column(
      children: [
        for (final entry in entries)
          PointyDetailRow(label: entry.key, value: _stringValue(entry.value)),
      ],
    );
  }

  String _stringValue(Object? value) {
    if (value == null || value.toString().isEmpty) {
      return '-';
    }
    return value.toString();
  }
}

String analyticsEventTypeLabel(AppLocalizations l10n, AnalyticsEventType type) {
  return switch (type) {
    AnalyticsEventType.usage => l10n.analyticsEventTypeUsage,
    AnalyticsEventType.error => l10n.analyticsEventTypeError,
    AnalyticsEventType.performance => l10n.analyticsEventTypePerformance,
    AnalyticsEventType.security => l10n.analyticsEventTypeSecurity,
    AnalyticsEventType.fraudSignal => l10n.analyticsEventTypeFraudSignal,
    AnalyticsEventType.audit => l10n.analyticsEventTypeAudit,
  };
}

String analyticsSeverityLabel(
  AppLocalizations l10n,
  AnalyticsEventSeverity severity,
) {
  return switch (severity) {
    AnalyticsEventSeverity.debug => l10n.analyticsSeverityDebug,
    AnalyticsEventSeverity.info => l10n.analyticsSeverityInfo,
    AnalyticsEventSeverity.warning => l10n.analyticsSeverityWarning,
    AnalyticsEventSeverity.error => l10n.analyticsSeverityError,
    AnalyticsEventSeverity.critical => l10n.analyticsSeverityCritical,
  };
}

String analyticsSourceLabel(
  AppLocalizations l10n,
  AnalyticsEventSource source,
) {
  return switch (source) {
    AnalyticsEventSource.frontend => l10n.analyticsSourceFrontend,
    AnalyticsEventSource.backend => l10n.analyticsSourceBackend,
    AnalyticsEventSource.printAgent => l10n.analyticsSourcePrintAgent,
    AnalyticsEventSource.integration => l10n.analyticsSourceIntegration,
  };
}

String _orEmpty(AppLocalizations l10n, String value) {
  return value.trim().isEmpty ? l10n.activityLogMissingValue : value;
}

IconData _eventTypeIcon(AnalyticsEventType type) {
  return switch (type) {
    AnalyticsEventType.usage => Icons.ads_click_outlined,
    AnalyticsEventType.error => Icons.error_outline,
    AnalyticsEventType.performance => Icons.speed_outlined,
    AnalyticsEventType.security => Icons.security_outlined,
    AnalyticsEventType.fraudSignal => Icons.gpp_maybe_outlined,
    AnalyticsEventType.audit => Icons.fact_check_outlined,
  };
}

IconData _eventSeverityIcon(AnalyticsEventSeverity severity) {
  return switch (severity) {
    AnalyticsEventSeverity.debug => Icons.bug_report_outlined,
    AnalyticsEventSeverity.info => Icons.info_outline,
    AnalyticsEventSeverity.warning => Icons.warning_amber_outlined,
    AnalyticsEventSeverity.error => Icons.error_outline,
    AnalyticsEventSeverity.critical => Icons.priority_high,
  };
}

Color _severityColor(BuildContext context, AnalyticsEventSeverity severity) {
  final colorScheme = Theme.of(context).colorScheme;
  return switch (severity) {
    AnalyticsEventSeverity.debug => colorScheme.outline,
    AnalyticsEventSeverity.info => colorScheme.primary,
    AnalyticsEventSeverity.warning => colorScheme.tertiary,
    AnalyticsEventSeverity.error => colorScheme.error,
    AnalyticsEventSeverity.critical => colorScheme.error,
  };
}

Color _riskColor(BuildContext context, int riskScore) {
  final colorScheme = Theme.of(context).colorScheme;
  if (riskScore >= 70) {
    return colorScheme.error;
  }
  if (riskScore >= 50) {
    return colorScheme.tertiary;
  }
  return colorScheme.primary;
}
