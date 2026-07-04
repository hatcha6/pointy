import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/business_alert.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/notification_center_view_model.dart';

class NotificationCenterDrawer extends StatelessWidget {
  const NotificationCenterDrawer({
    super.key,
    required this.viewModel,
    this.onOpenAlert,
  });

  final NotificationCenterViewModel viewModel;
  final Future<void> Function(BuildContext context, BusinessAlert alert)?
  onOpenAlert;

  @override
  Widget build(BuildContext context) {
    final width = math.min(MediaQuery.sizeOf(context).width * 0.92, 420.0);
    return Drawer(
      width: width,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) {
            return _NotificationCenterBody(
              viewModel: viewModel,
              onOpenAlert: onOpenAlert,
            );
          },
        ),
      ),
    );
  }
}

class _NotificationCenterBody extends StatelessWidget {
  const _NotificationCenterBody({
    required this.viewModel,
    required this.onOpenAlert,
  });

  final NotificationCenterViewModel viewModel;
  final Future<void> Function(BuildContext context, BusinessAlert alert)?
  onOpenAlert;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final alerts = viewModel.activeAlerts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.md,
            spacing.sm,
            spacing.xs,
            spacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.smartNotificationsTitle,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(l10n),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.pointyColors.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.smartNotificationsRefreshTooltip,
                onPressed: viewModel.isLoading
                    ? null
                    : () => unawaited(viewModel.refresh()),
                icon: const Icon(Icons.sync),
              ),
              if (viewModel.hiddenCount > 0)
                IconButton(
                  tooltip: l10n.smartNotificationsRestoreTooltip,
                  onPressed: () => unawaited(viewModel.restoreHiddenAlerts()),
                  icon: const Icon(Icons.visibility_outlined),
                ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: Navigator.of(context).pop,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (viewModel.hasError)
          Padding(
            padding: EdgeInsets.all(spacing.md),
            child: PointyInlineMessage.error(
              message: l10n.smartNotificationsLoadError,
              compact: true,
            ),
          ),
        if (viewModel.isLoading && !viewModel.hasLoaded)
          const Expanded(child: PointyLoadingArea())
        else if (alerts.isEmpty)
          Expanded(
            child: PointyEmptyState(
              icon: viewModel.hiddenCount > 0
                  ? Icons.visibility_off_outlined
                  : Icons.notifications_none_outlined,
              title: viewModel.hiddenCount > 0
                  ? l10n.smartNotificationsHiddenOnlyTitle
                  : l10n.smartNotificationsEmptyTitle,
              message: viewModel.hiddenCount > 0
                  ? l10n.smartNotificationsHiddenOnlyMessage
                  : l10n.smartNotificationsEmptyMessage,
              action: viewModel.hiddenCount > 0
                  ? OutlinedButton.icon(
                      onPressed: () =>
                          unawaited(viewModel.restoreHiddenAlerts()),
                      icon: const Icon(Icons.visibility_outlined),
                      label: Text(l10n.smartNotificationsRestoreHiddenButton),
                    )
                  : null,
            ),
          )
        else
          Expanded(
            child: RefreshIndicator(
              onRefresh: viewModel.refresh,
              child: ListView.separated(
                padding: EdgeInsets.all(spacing.md),
                itemCount: alerts.length + 1,
                separatorBuilder: (context, index) =>
                    SizedBox(height: spacing.sm),
                itemBuilder: (context, index) {
                  if (index == alerts.length) {
                    return _FooterActions(viewModel: viewModel);
                  }
                  return _NotificationAlertRow(
                    alert: alerts[index],
                    onReview: onOpenAlert == null
                        ? null
                        : () => unawaited(onOpenAlert!(context, alerts[index])),
                    onDismiss: () =>
                        unawaited(viewModel.dismissAlert(alerts[index].id)),
                    onSnooze: () =>
                        unawaited(viewModel.snoozeAlert(alerts[index].id)),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  String _subtitle(AppLocalizations l10n) {
    final generatedAt = viewModel.generatedAt;
    if (generatedAt == null) {
      return l10n.smartNotificationsActiveCount(viewModel.activeCount);
    }
    return l10n.smartNotificationsLastUpdated(formatDateTime(generatedAt));
  }
}

class _FooterActions extends StatelessWidget {
  const _FooterActions({required this.viewModel});

  final NotificationCenterViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: OutlinedButton.icon(
        onPressed: viewModel.activeAlerts.isEmpty
            ? null
            : () => unawaited(viewModel.dismissActiveAlerts()),
        icon: const Icon(Icons.done_all_outlined),
        label: Text(l10n.smartNotificationsDismissAllButton),
      ),
    );
  }
}

class _NotificationAlertRow extends StatelessWidget {
  const _NotificationAlertRow({
    required this.alert,
    required this.onReview,
    required this.onDismiss,
    required this.onSnooze,
  });

  final BusinessAlert alert;
  final VoidCallback? onReview;
  final VoidCallback onDismiss;
  final VoidCallback onSnooze;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final severityColor = _severityColor(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: severityColor.withOpacity(0.22)),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      severityColor.withOpacity(0.10),
                      colors.surface,
                    ),
                    borderRadius: BorderRadius.circular(PointyRadii.button),
                  ),
                  child: Icon(_icon(), color: severityColor, size: 20),
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          PointyStatusPill(
                            label: _severityLabel(l10n),
                            color: severityColor,
                          ),
                          PointyStatusPill(
                            label: _categoryLabel(l10n),
                            color: colors.primaryStrong,
                          ),
                        ],
                      ),
                      SizedBox(height: spacing.xs),
                      Text(
                        _title(l10n),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: spacing.xs),
                      Text(
                        _message(l10n),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            _detailWidget(context, l10n),
            SizedBox(height: spacing.sm),
            Row(
              children: [
                if (_canReview && onReview != null) ...[
                  FilledButton.tonalIcon(
                    onPressed: onReview,
                    icon: const Icon(Icons.manage_search_outlined),
                    label: Text(l10n.smartNotificationReviewAction),
                  ),
                  SizedBox(width: spacing.xs),
                ],
                TextButton.icon(
                  onPressed: onSnooze,
                  icon: const Icon(Icons.schedule_outlined),
                  label: Text(l10n.smartNotificationSnoozeAction),
                ),
                const Spacer(),
                IconButton(
                  tooltip: l10n.smartNotificationDismissTooltip,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailWidget(BuildContext context, AppLocalizations l10n) {
    final detail = _detail(l10n);
    if (detail.isEmpty) {
      return const SizedBox.shrink();
    }
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsets.only(top: spacing.sm),
      child: PointyInlineMessage(message: detail, compact: true),
    );
  }

  Color _severityColor(BuildContext context) {
    final colors = context.pointyColors;
    return switch (alert.severity) {
      BusinessAlertSeverity.critical => colors.danger,
      BusinessAlertSeverity.warning => colors.warning,
      BusinessAlertSeverity.info => colors.primaryStrong,
    };
  }

  bool get _canReview {
    return alert.hasInvestigationQuery ||
        alert.type == BusinessAlertType.payrollReady;
  }

  IconData _icon() {
    return switch (alert.type) {
      BusinessAlertType.outOfStock => Icons.inventory_2_outlined,
      BusinessAlertType.lowStock => Icons.production_quantity_limits_outlined,
      BusinessAlertType.expiringStock => Icons.event_busy_outlined,
      BusinessAlertType.overduePurchases => Icons.event_busy_outlined,
      BusinessAlertType.printFailures => Icons.print_disabled_outlined,
      BusinessAlertType.stalePrintAgents => Icons.wifi_off_outlined,
      BusinessAlertType.suspectedCashierActivity =>
        Icons.manage_search_outlined,
      BusinessAlertType.registerVariance => Icons.point_of_sale_outlined,
      BusinessAlertType.lowProfitMargin => Icons.warning_amber_outlined,
      BusinessAlertType.expiringDiscounts => Icons.local_offer_outlined,
      BusinessAlertType.payrollReady => Icons.payments_outlined,
      BusinessAlertType.operationsError => Icons.error_outline,
      BusinessAlertType.unknown => Icons.notifications_outlined,
    };
  }

  String _severityLabel(AppLocalizations l10n) {
    return switch (alert.severity) {
      BusinessAlertSeverity.critical => l10n.smartNotificationSeverityCritical,
      BusinessAlertSeverity.warning => l10n.smartNotificationSeverityWarning,
      BusinessAlertSeverity.info => l10n.smartNotificationSeverityInfo,
    };
  }

  String _categoryLabel(AppLocalizations l10n) {
    return switch (alert.category) {
      BusinessAlertCategory.inventory =>
        l10n.smartNotificationCategoryInventory,
      BusinessAlertCategory.purchasing =>
        l10n.smartNotificationCategoryPurchasing,
      BusinessAlertCategory.printing => l10n.smartNotificationCategoryPrinting,
      BusinessAlertCategory.sales => l10n.smartNotificationCategorySales,
      BusinessAlertCategory.fraud => l10n.smartNotificationCategoryFraud,
      BusinessAlertCategory.discounts =>
        l10n.smartNotificationCategoryDiscounts,
      BusinessAlertCategory.operations =>
        l10n.smartNotificationCategoryOperations,
    };
  }

  String _title(AppLocalizations l10n) {
    return switch (alert.type) {
      BusinessAlertType.outOfStock => l10n.smartNotificationOutOfStockTitle,
      BusinessAlertType.lowStock => l10n.smartNotificationLowStockTitle,
      BusinessAlertType.expiringStock =>
        l10n.smartNotificationExpiringStockTitle,
      BusinessAlertType.overduePurchases =>
        l10n.smartNotificationOverduePurchasesTitle,
      BusinessAlertType.printFailures =>
        l10n.smartNotificationPrintFailuresTitle,
      BusinessAlertType.stalePrintAgents =>
        l10n.smartNotificationStalePrintAgentsTitle,
      BusinessAlertType.suspectedCashierActivity =>
        l10n.smartNotificationSuspectedActivityTitle,
      BusinessAlertType.registerVariance =>
        l10n.smartNotificationRegisterVarianceTitle,
      BusinessAlertType.lowProfitMargin =>
        l10n.smartNotificationLowProfitMarginTitle,
      BusinessAlertType.expiringDiscounts =>
        l10n.smartNotificationExpiringDiscountsTitle,
      BusinessAlertType.payrollReady => l10n.smartNotificationPayrollReadyTitle,
      BusinessAlertType.operationsError =>
        l10n.smartNotificationOperationsErrorTitle,
      BusinessAlertType.unknown => l10n.smartNotificationUnknownTitle,
    };
  }

  String _message(AppLocalizations l10n) {
    return switch (alert.type) {
      BusinessAlertType.outOfStock => l10n.smartNotificationOutOfStockMessage(
        alert.count,
      ),
      BusinessAlertType.lowStock => l10n.smartNotificationLowStockMessage(
        alert.count,
      ),
      BusinessAlertType.expiringStock =>
        l10n.smartNotificationExpiringStockMessage(alert.count, alert.days),
      BusinessAlertType.overduePurchases =>
        l10n.smartNotificationOverduePurchasesMessage(
          alert.count,
          formatMoney(alert.amount),
        ),
      BusinessAlertType.printFailures =>
        l10n.smartNotificationPrintFailuresMessage(alert.count),
      BusinessAlertType.stalePrintAgents =>
        l10n.smartNotificationStalePrintAgentsMessage(
          alert.count,
          alert.quantity,
        ),
      BusinessAlertType.suspectedCashierActivity =>
        l10n.smartNotificationSuspectedActivityMessage(
          alert.primaryLabel,
          alert.riskScore,
        ),
      BusinessAlertType.registerVariance =>
        l10n.smartNotificationRegisterVarianceMessage(
          alert.count,
          formatMoney(alert.amount),
        ),
      BusinessAlertType.lowProfitMargin =>
        l10n.smartNotificationLowProfitMarginMessage(
          alert.percent.toStringAsFixed(0),
          formatMoney(alert.amount),
        ),
      BusinessAlertType.expiringDiscounts =>
        l10n.smartNotificationExpiringDiscountsMessage(alert.count, alert.days),
      BusinessAlertType.payrollReady =>
        l10n.smartNotificationPayrollReadyMessage(
          alert.count,
          formatMoney(alert.amount),
        ),
      BusinessAlertType.operationsError =>
        l10n.smartNotificationOperationsErrorMessage(
          alert.primaryLabel,
          alert.secondaryLabel,
        ),
      BusinessAlertType.unknown => l10n.smartNotificationUnknownMessage,
    };
  }

  String _detail(AppLocalizations l10n) {
    return switch (alert.type) {
      BusinessAlertType.outOfStock || BusinessAlertType.lowStock =>
        alert.primaryLabel.isEmpty
            ? ''
            : l10n.smartNotificationStockDetail(
                alert.primaryLabel,
                alert.quantity,
                alert.threshold,
              ),
      BusinessAlertType.overduePurchases =>
        alert.primaryLabel.isEmpty
            ? ''
            : l10n.smartNotificationOverduePurchaseDetail(
                alert.primaryLabel,
                alert.secondaryLabel,
              ),
      BusinessAlertType.expiringStock =>
        alert.primaryLabel.isEmpty || alert.occurredAt == null
            ? ''
            : _expiringStockDetail(l10n),
      BusinessAlertType.printFailures => alert.secondaryLabel,
      BusinessAlertType.suspectedCashierActivity => alert.detailLabel,
      BusinessAlertType.expiringDiscounts =>
        alert.primaryLabel.isEmpty
            ? ''
            : l10n.smartNotificationDiscountDetail(alert.primaryLabel),
      BusinessAlertType.payrollReady =>
        alert.primaryLabel.isEmpty
            ? ''
            : l10n.smartNotificationPayrollReadyDetail(
                alert.primaryLabel,
                alert.secondaryLabel,
                alert.detailLabel,
              ),
      BusinessAlertType.operationsError => alert.detailLabel,
      BusinessAlertType.stalePrintAgents ||
      BusinessAlertType.registerVariance ||
      BusinessAlertType.lowProfitMargin ||
      BusinessAlertType.unknown => '',
    };
  }

  String _expiringStockDetail(AppLocalizations l10n) {
    final context = alert.detailLabel.isEmpty
        ? alert.secondaryLabel
        : alert.detailLabel;
    if (context.isEmpty) {
      return l10n.smartNotificationExpiringStockDetailBasic(
        alert.primaryLabel,
        alert.quantity,
        formatDate(alert.occurredAt!),
      );
    }
    return l10n.smartNotificationExpiringStockDetail(
      alert.primaryLabel,
      alert.quantity,
      formatDate(alert.occurredAt!),
      context,
    );
  }
}
