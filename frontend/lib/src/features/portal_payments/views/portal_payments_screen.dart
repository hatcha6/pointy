import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/contact.dart';
import '../../../data/models/portal_payment.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../register_sessions/views/sale_order_details_sheet.dart';
import '../view_models/portal_payments_view_model.dart';
import 'portal_payment_presentation.dart';
import 'record_portal_payment_sheet.dart';

/// Top-ups somebody did on the provider's own website, and turning each into
/// the invoice the till could not issue at the time.
///
/// Opened from the register sessions, because that is what it fixes: a drawer
/// holding cash no sale explains, and a provider float lower than Pointy's
/// arithmetic says. Every row is a payment the provider itself printed.
class PortalPaymentsScreen extends StatefulWidget {
  const PortalPaymentsScreen({
    super.key,
    required this.viewModel,
    required this.providerName,
    this.pickCustomer,
    this.loadTrustedTerminalIds,
    this.loadOrderDetail,
  });

  final PortalPaymentsViewModel viewModel;
  final String providerName;
  final Future<Customer?> Function(BuildContext context)? pickCustomer;
  final Future<List<String>> Function()? loadTrustedTerminalIds;

  /// Opens a recorded payment's invoice. Null leaves the invoice as text.
  final SaleOrderDetailLoader? loadOrderDetail;

  @override
  State<PortalPaymentsScreen> createState() => _PortalPaymentsScreenState();
}

class _PortalPaymentsScreenState extends State<PortalPaymentsScreen> {
  PortalPaymentsViewModel get viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && viewModel.day == null) unawaited(viewModel.load());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.portalPaymentsTitle(widget.providerName)),
            isLoading: viewModel.isLoading,
            actions: [
              IconButton(
                key: const ValueKey('portal_payments_pick_date'),
                tooltip: l10n.portalPaymentsPickDateTooltip,
                onPressed: viewModel.isLoading ? null : _pickDate,
                icon: const Icon(Icons.calendar_month_outlined),
              ),
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _body(context, l10n),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    final day = viewModel.day;
    if (day == null) {
      if (viewModel.failure != null) {
        return PointyErrorState(
          title: l10n.portalPaymentsLoadError,
          icon: Icons.cloud_off_outlined,
          action: FilledButton.icon(
            onPressed: viewModel.load,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return ListView(
        padding: spacing.pagePadding,
        children: const [
          PointySkeletonListTile(),
          PointySkeletonListTile(),
          PointySkeletonListTile(),
        ],
      );
    }
    final payments = viewModel.visiblePayments;
    return RefreshIndicator(
      onRefresh: viewModel.load,
      child: ListView(
        padding: spacing.pagePadding,
        children: [
          _DayHeader(
            day: day,
            date: viewModel.date,
            isToday: viewModel.isToday,
            providerName: widget.providerName,
            showAll: viewModel.showAll,
            onShowAll: viewModel.setShowAll,
          ),
          SizedBox(height: spacing.md),
          if (payments.isEmpty)
            PointyEmptyState(
              icon: Icons.task_alt_outlined,
              title: viewModel.showAll
                  ? l10n.portalPaymentsEmptyDayTitle
                  : l10n.portalPaymentsEmptyTitle,
              message: viewModel.showAll
                  ? null
                  : l10n.portalPaymentsEmptyBody(widget.providerName),
            )
          else
            for (final payment in payments) ...[
              PortalPaymentRow(
                payment: payment,
                onTap: () => _open(context, day, payment),
              ),
              SizedBox(height: spacing.sm),
            ],
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: viewModel.date,
      firstDate: now.subtract(const Duration(days: 90)),
      lastDate: now,
    );
    if (picked != null) await viewModel.setDate(picked);
  }

  Future<void> _open(
    BuildContext context,
    PortalPaymentsDay day,
    PortalPayment payment,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final order = payment.order;
    if (payment.state == PortalPaymentState.recorded) {
      final loader = widget.loadOrderDetail;
      if (order != null && loader != null) {
        await showSaleOrderDetailsSheetForId(
          context,
          order.id,
          loadDetail: loader,
        );
      }
      return;
    }
    final whyNot = portalPaymentWhyNot(payment, l10n);
    if (whyNot != null || !payment.recordable) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(whyNot ?? l10n.portalPaymentsErrorGeneric)),
        );
      return;
    }
    final outcome = await showRecordPortalPaymentSheet(
      context,
      payment: payment,
      day: day,
      providerName: widget.providerName,
      onRecord: (draft) => viewModel.record(payment, draft),
      onLink: (candidate) => viewModel.link(payment, candidate),
      pickCustomer: widget.pickCustomer,
      loadTrustedTerminalIds: widget.loadTrustedTerminalIds,
    );
    if (outcome == null || !context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            outcome.linked
                ? l10n.portalPaymentsLinked(outcome.order.receiptNumber)
                : l10n.portalPaymentsRecorded(outcome.order.receiptNumber),
          ),
        ),
      );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.date,
    required this.isToday,
    required this.providerName,
    required this.showAll,
    required this.onShowAll,
  });

  final PortalPaymentsDay day;
  final DateTime date;
  final bool isToday;
  final String providerName;
  final bool showAll;
  final ValueChanged<bool> onShowAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.portalPaymentsIntro(providerName),
          style: theme.textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
        ),
        SizedBox(height: spacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PointyStatusPill(
              label: isToday ? l10n.portalPaymentsToday : formatDate(date),
              icon: Icons.today_outlined,
              compact: false,
            ),
            PointyStatusPill(
              key: const ValueKey('portal_payments_unrecorded_summary'),
              label: day.unrecordedCount == 0
                  ? l10n.portalPaymentsSummaryUnrecorded(0)
                  : '${l10n.portalPaymentsSummaryUnrecorded(day.unrecordedCount)}'
                        ' · ${formatMoney(day.unrecordedAmount)}',
              icon: day.unrecordedCount == 0
                  ? Icons.task_alt_outlined
                  : Icons.error_outline,
              color: day.unrecordedCount == 0 ? colors.success : colors.danger,
              compact: false,
            ),
            if (day.pendingSaleCount > 0)
              PointyStatusPill(
                label: l10n.portalPaymentsSummaryPending(day.pendingSaleCount),
                icon: Icons.link_outlined,
                color: colors.warning,
                compact: false,
              ),
          ],
        ),
        SizedBox(height: spacing.sm),
        if (!day.readOk)
          PointyInlineMessage.warning(
            key: const ValueKey('portal_payments_read_failed'),
            message: l10n.portalPaymentsReadFailed(providerName),
            compact: true,
          )
        else if (!day.complete)
          PointyInlineMessage.warning(
            message: l10n.portalPaymentsIncomplete(providerName),
            compact: true,
          )
        else if (day.readAt != null)
          Text(
            l10n.portalPaymentsReadAt(providerName, formatTime(day.readAt!)),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        SizedBox(height: spacing.sm),
        SegmentedButton<bool>(
          key: const ValueKey('portal_payments_filter'),
          segments: [
            ButtonSegment(
              value: false,
              label: Text(l10n.portalPaymentsFilterUnrecorded),
            ),
            ButtonSegment(
              value: true,
              label: Text(l10n.portalPaymentsFilterAll),
            ),
          ],
          selected: {showAll},
          onSelectionChanged: (selection) => onShowAll(selection.first),
        ),
      ],
    );
  }
}

/// One payment: when, how much, whose line, and where it stands.
class PortalPaymentRow extends StatelessWidget {
  const PortalPaymentRow({super.key, required this.payment, this.onTap});

  final PortalPayment payment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final order = payment.order;
    final who = payment.subscriberName.isEmpty
        ? payment.subscriberRef
        : '${payment.subscriberName} · ${payment.subscriberRef}';
    final detail = switch (payment.state) {
      PortalPaymentState.recorded when order != null =>
        l10n.portalPaymentsRecordedIn(order.receiptNumber, order.cashierName),
      PortalPaymentState.notVerified => portalPaymentProviderStatusLabel(
        payment,
        l10n,
      ),
      PortalPaymentState.otherOperator => payment.operatorName,
      _ => l10n.portalPaymentsSerial(payment.reference),
    };
    return Material(
      key: ValueKey('portal_payment_row_${payment.reference}'),
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsetsDirectional.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  payment.paidAt == null ? '' : formatTime(payment.paidAt!),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      who,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PointyStatusPill(
                          label: portalPaymentStateLabel(payment.state, l10n),
                          icon: portalPaymentStateIcon(payment.state),
                          color: portalPaymentStateColor(payment.state, colors),
                        ),
                        Text(
                          detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              Text(
                formatMoney(payment.amount ?? 0),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
