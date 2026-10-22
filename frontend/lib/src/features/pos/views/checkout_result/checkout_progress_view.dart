import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/sale_order.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../view_models/pos_view_model.dart';

/// A provider that has not answered after this long gets a line saying the
/// till is still waiting, so a slow card does not read as a hung screen.
const Duration checkoutSlowChargeAfter = Duration(seconds: 15);

/// The sale being sent: what it is doing, what it has done, what is left.
///
/// [progress] is null in the moment before the view model has started — the
/// first step is then the one running.
class CheckoutProgressView extends StatefulWidget {
  const CheckoutProgressView({
    super.key,
    required this.progress,
    required this.saleType,
    required this.total,
  });

  final PosCheckoutProgress? progress;
  final SaleType saleType;
  final double total;

  @override
  State<CheckoutProgressView> createState() => _CheckoutProgressViewState();
}

class _CheckoutProgressViewState extends State<CheckoutProgressView> {
  Timer? _ticker;

  /// Seconds spent waiting on the provider: counted, not read off the clock,
  /// so what is on screen is exactly how long the cashier has been looking.
  late int _chargeSeconds = _initialChargeSeconds();

  int _initialChargeSeconds() {
    final startedAt = widget.progress?.chargeStartedAt;
    return startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inSeconds.clamp(0, 86400);
  }

  @override
  void initState() {
    super.initState();
    // Redrawn each second only for the wait on a provider, where the count is
    // the cashier's proof the till is alive.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.progress?.step == PosCheckoutStep.charge) {
        setState(() => _chargeSeconds++);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final progress = widget.progress;
    final steps = [
      PosCheckoutStep.record,
      if (progress?.charges ?? false) PosCheckoutStep.charge,
      if (progress?.prints ?? false) PosCheckoutStep.print,
    ];
    final current = steps.indexOf(progress?.step ?? PosCheckoutStep.record);

    PointyStageStatus statusOf(int index) => index < current
        ? PointyStageStatus.done
        : index == current
        ? PointyStageStatus.running
        : PointyStageStatus.pending;

    String chargeDetail() {
      final labels = progress?.chargeLabels.join('، ') ?? '';
      if (progress?.step != PosCheckoutStep.charge ||
          _chargeSeconds < checkoutSlowChargeAfter.inSeconds) {
        return labels;
      }
      return l10n.checkoutResultStepChargeSlow(_chargeSeconds);
    }

    return PointyResultPanel(
      key: const ValueKey('checkout_progress'),
      tone: PointyResultTone.working,
      title: widget.saleType == SaleType.quotation
          ? l10n.checkoutResultWorkingQuotationTitle
          : l10n.checkoutResultWorkingTitle,
      subtitle: formatMoney(widget.total),
      footer: Text(
        l10n.checkoutResultWorkingHint,
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: context.pointyColors.mutedInk),
      ),
      children: [
        PointyStageTimeline(
          // The spinner at the top already says it is working.
          showRunningBar: false,
          stages: [
            for (final (index, step) in steps.indexed)
              PointyStageEntry(
                label: switch (step) {
                  PosCheckoutStep.record => l10n.checkoutResultStepRecord,
                  PosCheckoutStep.charge => l10n.checkoutResultStepCharge,
                  PosCheckoutStep.print => l10n.checkoutResultStepPrint,
                },
                status: statusOf(index),
                detail: step == PosCheckoutStep.charge ? chargeDetail() : '',
              ),
          ],
        ),
      ],
    );
  }
}
