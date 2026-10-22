import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/services/order_document_service.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../settings/views/messaging_presentation.dart';
import '../../view_models/pos_view_model.dart';

/// What the result of a sale can do with its invoice, each a call the caller
/// wires to the view model. A null action is not offered.
class CheckoutReceiptHandlers {
  const CheckoutReceiptHandlers({
    required this.print,
    this.share,
    this.sendSms,
    this.printProof,
  });

  final Future<InvoicePrintStatus> Function() print;
  final Future<OrderDocumentActionStatus> Function()? share;

  /// Null once queued; otherwise why not, in the server's code and words.
  final Future<({String code, String detail})?> Function(String phone)? sendSms;
  final Future<bool> Function()? printProof;
}

/// The receipt's state on this till — printed, failed, no printer — and every
/// other way to hand the customer their invoice.
///
/// Feedback stays inside the result instead of a snackbar, which would sit
/// under the dialog's barrier where nobody reads it.
class CheckoutReceiptActions extends StatefulWidget {
  const CheckoutReceiptActions({
    super.key,
    required this.initialPrintStatus,
    required this.handlers,
    this.customerPhone = '',
  });

  final InvoicePrintStatus initialPrintStatus;
  final CheckoutReceiptHandlers handlers;

  /// Proposed in the SMS box; the cashier may type another.
  final String customerPhone;

  @override
  State<CheckoutReceiptActions> createState() => _CheckoutReceiptActionsState();
}

enum _Busy { print, share, sms, proof }

class _CheckoutReceiptActionsState extends State<CheckoutReceiptActions> {
  late var _printStatus = widget.initialPrintStatus;
  _Busy? _busy;
  ({bool ok, String message})? _feedback;

  Future<void> _run(
    _Busy which,
    Future<({bool ok, String message})?> Function() action,
  ) async {
    if (_busy != null) return;
    setState(() {
      _busy = which;
      _feedback = null;
    });
    final feedback = await action();
    if (!mounted) return;
    setState(() {
      _busy = null;
      _feedback = feedback;
    });
  }

  Future<void> _print() => _run(_Busy.print, () async {
    final status = await widget.handlers.print();
    if (mounted) setState(() => _printStatus = status);
    return null;
  });

  Future<void> _share(AppLocalizations l10n) => _run(_Busy.share, () async {
    final status = await widget.handlers.share!();
    return switch (status) {
      OrderDocumentActionStatus.completed => (
        ok: true,
        message: l10n.invoiceShareSuccess,
      ),
      OrderDocumentActionStatus.failed => (
        ok: false,
        message: l10n.invoiceShareError,
      ),
      OrderDocumentActionStatus.canceled => null,
    };
  });

  Future<void> _proof(AppLocalizations l10n) => _run(_Busy.proof, () async {
    final printed = await widget.handlers.printProof!();
    return printed
        ? (ok: true, message: l10n.checkoutResultProofPrinted)
        : (ok: false, message: l10n.checkoutResultProofFailed);
  });

  Future<void> _sms(AppLocalizations l10n) async {
    final phone = await showDialog<String>(
      context: context,
      builder: (_) => PointyTextEntryDialog(
        title: l10n.checkoutSmsTitle,
        message: l10n.checkoutSmsBody,
        fieldLabel: l10n.checkoutSmsPhoneLabel,
        confirmLabel: l10n.checkoutSmsSend,
        initialValue: widget.customerPhone,
        icon: Icons.sms_outlined,
        fieldPrefixIcon: Icons.phone_outlined,
        fieldTextDirection: TextDirection.ltr,
      ),
    );
    if (phone == null || !mounted) return;
    if (phone.trim().isEmpty) {
      setState(
        () => _feedback = (ok: false, message: l10n.checkoutSmsPhoneRequired),
      );
      return;
    }
    await _run(_Busy.sms, () async {
      final refusal = await widget.handlers.sendSms!(phone.trim());
      if (refusal == null) {
        return (ok: true, message: l10n.checkoutResultSmsSent);
      }
      return (
        ok: false,
        message: messagingFailureMessage(
          l10n,
          code: refusal.code,
          detail: refusal.detail,
          fallback: l10n.checkoutResultSmsFailed,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final handlers = widget.handlers;
    final feedback = _feedback;

    Widget action({
      required _Busy which,
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
    }) {
      final busy = _busy == which;
      return OutlinedButton.icon(
        key: ValueKey('checkout_action_${which.name}'),
        onPressed: _busy == null ? onPressed : null,
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        icon: busy
            ? const SizedBox.square(
                dimension: 16,
                child: PointySpinner(strokeWidth: 2),
              )
            : Icon(icon, size: 18),
        label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
      );
    }

    final actions = [
      action(
        which: _Busy.print,
        icon: Icons.print_outlined,
        label: _printStatus == InvoicePrintStatus.notRequested
            ? l10n.checkoutResultPrintAction
            : l10n.checkoutResultReprintAction,
        onPressed: _print,
      ),
      if (handlers.sendSms != null)
        action(
          which: _Busy.sms,
          icon: Icons.sms_outlined,
          label: l10n.checkoutResultSmsAction,
          onPressed: () => _sms(l10n),
        ),
      if (handlers.share != null)
        action(
          which: _Busy.share,
          icon: Icons.ios_share_rounded,
          label: l10n.checkoutResultShareAction,
          onPressed: () => _share(l10n),
        ),
      if (handlers.printProof != null)
        action(
          which: _Busy.proof,
          icon: Icons.receipt_long_outlined,
          label: l10n.checkoutResultProofAction,
          onPressed: () => _proof(l10n),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PrintStatusLine(status: _printStatus, printing: _busy == _Busy.print),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 300 ? 1 : 2;
            const gap = 8.0;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final button in actions)
                  SizedBox(width: width, child: button),
              ],
            );
          },
        ),
        if (feedback != null) ...[
          const SizedBox(height: 8),
          PointyInlineMessage(
            key: const ValueKey('checkout_action_feedback'),
            message: feedback.message,
            compact: true,
            icon: feedback.ok
                ? Icons.check_circle_outline
                : Icons.error_outline,
            tone: feedback.ok
                ? PointyInlineMessageTone.success
                : PointyInlineMessageTone.error,
          ),
        ],
      ],
    );
  }
}

class _PrintStatusLine extends StatelessWidget {
  const _PrintStatusLine({required this.status, required this.printing});

  final InvoicePrintStatus status;
  final bool printing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final (Color color, IconData icon, String text, String? hint) = printing
        ? (
            colors.primaryStrong,
            Icons.print_outlined,
            l10n.checkoutResultPrinting,
            null,
          )
        : switch (status) {
            InvoicePrintStatus.printed => (
              colors.success,
              Icons.check_circle_outline,
              l10n.checkoutResultPrinted,
              null,
            ),
            InvoicePrintStatus.failed => (
              colors.danger,
              Icons.print_disabled_outlined,
              l10n.checkoutResultPrintFailed,
              null,
            ),
            InvoicePrintStatus.noPrinter => (
              colors.warning,
              Icons.print_disabled_outlined,
              l10n.checkoutResultNoPrinter,
              l10n.checkoutResultNoPrinterHint,
            ),
            InvoicePrintStatus.notRequested => (
              colors.mutedInk,
              Icons.receipt_outlined,
              l10n.checkoutResultNotPrinted,
              null,
            ),
          };
    return Semantics(
      liveRegion: true,
      child: Row(
        key: ValueKey(
          'checkout_print_status_${printing ? 'printing' : status.name}',
        ),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
