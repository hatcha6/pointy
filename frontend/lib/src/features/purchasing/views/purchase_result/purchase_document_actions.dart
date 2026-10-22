import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/services/order_document_service.dart';
import '../../../../shared/components/components.dart';

/// The purchase order as paper: printed for the storeroom or the supplier's
/// driver, shared as a PDF, and — once goods with identity are in — the
/// stickers for them. A null action is not offered.
///
/// Feedback stays inside the result instead of a snackbar, which would sit
/// under the dialog's barrier where nobody reads it.
class PurchaseDocumentActions extends StatefulWidget {
  const PurchaseDocumentActions({
    super.key,
    required this.onPrint,
    this.onShare,
    this.onPrintLabels,
  });

  final Future<bool> Function() onPrint;
  final Future<OrderDocumentActionStatus> Function()? onShare;
  final VoidCallback? onPrintLabels;

  @override
  State<PurchaseDocumentActions> createState() =>
      _PurchaseDocumentActionsState();
}

enum _Busy { print, share }

class _PurchaseDocumentActionsState extends State<PurchaseDocumentActions> {
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

  Future<void> _print(AppLocalizations l10n) => _run(_Busy.print, () async {
    final printed = await widget.onPrint();
    return printed
        ? (ok: true, message: l10n.purchaseResultPrinted)
        : (ok: false, message: l10n.purchaseOrderPrintError);
  });

  Future<void> _share(AppLocalizations l10n) => _run(_Busy.share, () async {
    final status = await widget.onShare!();
    return switch (status) {
      OrderDocumentActionStatus.completed => (
        ok: true,
        message: l10n.purchaseResultShared,
      ),
      OrderDocumentActionStatus.failed => (
        ok: false,
        message: l10n.purchaseOrderShareError,
      ),
      OrderDocumentActionStatus.canceled => null,
    };
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final feedback = _feedback;

    Widget action({
      required String name,
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
      bool busy = false,
    }) {
      return OutlinedButton.icon(
        key: ValueKey('purchase_result_action_$name'),
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
      if (widget.onPrintLabels case final onPrintLabels?)
        action(
          name: 'labels',
          icon: Icons.qr_code_2_rounded,
          label: l10n.receiptLabelsAction,
          onPressed: onPrintLabels,
        ),
      action(
        name: 'print',
        icon: Icons.print_outlined,
        label: l10n.purchaseOrderPrintAction,
        busy: _busy == _Busy.print,
        onPressed: () => _print(l10n),
      ),
      if (widget.onShare != null)
        action(
          name: 'share',
          icon: Icons.ios_share_rounded,
          label: l10n.purchaseOrderShareAction,
          busy: _busy == _Busy.share,
          onPressed: () => _share(l10n),
        ),
    ];

    return PointyResultSection(
      title: l10n.purchaseResultDocumentTitle,
      icon: Icons.description_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
              key: const ValueKey('purchase_result_action_feedback'),
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
      ),
    );
  }
}
