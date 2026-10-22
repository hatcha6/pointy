import 'package:flutter/material.dart';

import '../../../../data/models/sale_order.dart';
import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../view_models/pos_view_model.dart';
import '../payment/payment.dart';
import 'checkout_failure_view.dart';
import 'checkout_progress_view.dart';
import 'checkout_receipt_actions.dart';
import 'checkout_success_view.dart';

/// How the cashier left the sale's result.
sealed class PosCheckoutExit {
  const PosCheckoutExit();
}

/// The sale is recorded. [scannedCode] is the next customer's first item,
/// scanned straight over the result; [openShopSettings] asks to be taken to
/// the setting the result pointed at, once the sale's screens have closed.
final class PosCheckoutCompleted extends PosCheckoutExit {
  const PosCheckoutCompleted({this.scannedCode, this.openShopSettings = false});

  final String? scannedCode;
  final bool openShopSettings;
}

/// Not recorded; the cashier wants the payment sheet back.
final class PosCheckoutEditPayment extends PosCheckoutExit {
  const PosCheckoutEditPayment();
}

/// Nothing was sent: the cart's total moved after the tender was taken.
final class PosCheckoutTotalChanged extends PosCheckoutExit {
  const PosCheckoutTotalChanged();
}

/// Not recorded; back to the cart as it was.
final class PosCheckoutAbandoned extends PosCheckoutExit {
  const PosCheckoutAbandoned();
}

/// Sends the sale and stays up through all of it: the progress while it is
/// recorded, charged and printed, then the result in the same dialog — the
/// receipt's state, the link, the PINs, or why it was refused and what to do.
Future<PosCheckoutExit> showPosCheckoutDialog({
  required BuildContext context,
  required PosViewModel viewModel,
  required PaymentSheetResult payment,
  required bool soldInTestMode,
  required bool showLossAmounts,
  required bool canSendSms,
  bool canOpenSettings = false,
}) async {
  final exit = await showPointyResultDialog<PosCheckoutExit>(
    context: context,
    builder: (_) => PosCheckoutDialog(
      viewModel: viewModel,
      payment: payment,
      soldInTestMode: soldInTestMode,
      showLossAmounts: showLossAmounts,
      canSendSms: canSendSms,
      canOpenSettings: canOpenSettings,
    ),
  );
  return exit ?? const PosCheckoutAbandoned();
}

class PosCheckoutDialog extends StatefulWidget {
  const PosCheckoutDialog({
    super.key,
    required this.viewModel,
    required this.payment,
    required this.soldInTestMode,
    required this.showLossAmounts,
    required this.canSendSms,
    this.canOpenSettings = false,
  });

  final PosViewModel viewModel;
  final PaymentSheetResult payment;
  final bool soldInTestMode;
  final bool showLossAmounts;
  final bool canSendSms;
  final bool canOpenSettings;

  @override
  State<PosCheckoutDialog> createState() => _PosCheckoutDialogState();
}

class _PosCheckoutDialogState extends State<PosCheckoutDialog> {
  /// What the sheet tendered for, read once: the cart is cleared the moment
  /// the sale is recorded.
  late final double _total = widget.viewModel.total;
  SaleCheckoutOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    // After the first frame: the sale notifies the till the moment it starts,
    // and the dialog's own first build is not the time for that.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  Future<void> _run() async {
    if (_outcome != null) {
      setState(() => _outcome = null);
    }
    final payment = widget.payment;
    final outcome = await widget.viewModel.checkoutCurrentSale(
      payments: payment.payments,
      saleType: payment.saleType,
      validUntil: payment.validUntil,
      dueDate: payment.dueDate,
      reserveStock: payment.reserveStock,
    );
    if (!mounted) return;
    if (outcome.isTotalChanged) {
      Navigator.of(context).pop(const PosCheckoutTotalChanged());
      return;
    }
    setState(() => _outcome = outcome);
  }

  void _close(PosCheckoutExit exit) => Navigator.of(context).pop(exit);

  /// What the barrier, Escape or the back button mean right now — null while
  /// nothing may close the dialog.
  PosCheckoutExit? get _dismissal {
    final outcome = _outcome;
    if (outcome == null) return null;
    if (!outcome.isSuccess) return const PosCheckoutAbandoned();
    return CheckoutSuccessView.holdsOpen(outcome.recharges)
        ? null
        : const PosCheckoutCompleted();
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final Widget content;
    if (outcome == null) {
      content = ListenableBuilder(
        listenable: widget.viewModel,
        builder: (context, _) => CheckoutProgressView(
          progress: widget.viewModel.checkoutProgress,
          saleType: widget.payment.saleType,
          total: _total,
        ),
      );
    } else if (outcome.isSuccess && outcome.order != null) {
      content = _success(outcome);
    } else {
      content = CheckoutFailureView(
        outcome: outcome,
        showLossAmounts: widget.showLossAmounts,
        onRetry: _run,
        onEditPayment: () => _close(const PosCheckoutEditPayment()),
        onReviewCart: () => _close(const PosCheckoutAbandoned()),
      );
    }

    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return PopScope<PosCheckoutExit>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        final exit = _dismissal;
        if (!didPop && exit != null) _close(exit);
      },
      child: AnimatedSwitcher(
        duration: reduceMotion ? Duration.zero : PointyMotion.standard,
        layoutBuilder: (current, previous) => current ?? const SizedBox(),
        child: KeyedSubtree(
          key: ValueKey(
            outcome == null
                ? 'working'
                : outcome.isSuccess
                ? 'success'
                : 'failure',
          ),
          child: content,
        ),
      ),
    );
  }

  Widget _success(SaleCheckoutOutcome outcome) {
    final order = outcome.order!;
    final viewModel = widget.viewModel;
    final saleType = widget.payment.saleType;
    final holdsOpen = CheckoutSuccessView.holdsOpen(outcome.recharges);
    return BarcodeScanListener(
      // A PIN still to be handed over is not cleared away by the next scan.
      enabled: !holdsOpen,
      onBarcodeScanned: (code) =>
          _close(PosCheckoutCompleted(scannedCode: code)),
      child: CheckoutSuccessView(
        order: order,
        saleType: saleType,
        printStatus: outcome.printStatus,
        recharges: outcome.recharges,
        changeDue: widget.payment.changeDue,
        soldInTestMode: widget.soldInTestMode,
        onlineInvoicesEnabled: viewModel.onlineInvoicesEnabled,
        onOpenSettings: widget.canOpenSettings
            ? () => _close(const PosCheckoutCompleted(openShopSettings: true))
            : null,
        scanToContinue: !holdsOpen,
        onDone: () => _close(const PosCheckoutCompleted()),
        handlers: CheckoutReceiptHandlers(
          print: () =>
              viewModel.reprintPaidInvoice(order, recharges: outcome.recharges),
          share: () => viewModel.sharePaidInvoice(order),
          sendSms: widget.canSendSms
              ? (phone) => viewModel.sendPaidInvoiceSms(order, phone: phone)
              : null,
          printProof: saleType == SaleType.credit && order.payments.isNotEmpty
              ? () => viewModel.printDownPaymentProofs(order)
              : null,
        ),
      ),
    );
  }
}
