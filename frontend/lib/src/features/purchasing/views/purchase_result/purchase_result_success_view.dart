import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/purchase_submission.dart';
import '../../../../data/services/order_document_service.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/units.dart';
import '../../../../shared/tutor/anchors.dart';
import '../../../../shared/tutor/tutor_target.dart';
import '../purchase_receipt_hint.dart';
import 'purchase_document_actions.dart';
import 'purchase_result_buttons.dart';

/// "Order 12 • the supplier", the line under every purchase result's title.
String purchaseResultSubtitle(AppLocalizations l10n, PurchaseOrder order) {
  final supplier = order.supplierName?.trim() ?? '';
  return [
    if (order.orderNumber.isNotEmpty)
      l10n.purchaseResultOrderNumber(ltrIsolated(order.orderNumber)),
    if (supplier.isNotEmpty) supplier,
  ].join(' • ');
}

/// The order is recorded — sent, or its edits saved. Whether its goods are in
/// is the one question left, and when the buyer may answer it here, the main
/// button asks it.
class PurchaseRecordedView extends StatelessWidget {
  const PurchaseRecordedView({
    super.key,
    required this.order,
    required this.saved,
    required this.doneLabel,
    required this.onDone,
    this.onReceive,
    this.onReceiveAdjust,
    this.receiveError,
    this.onPrint,
    this.onShare,
  });

  final PurchaseOrder order;

  /// A reopened order's edits, rather than a new order sent.
  final bool saved;
  final String doneLabel;
  final VoidCallback onDone;

  /// Null where the goods cannot be received from here: the buyer may not, the
  /// order is still a draft, or nothing on it is open.
  final VoidCallback? onReceive;

  /// The receiving form for a delivery that did not match its paperwork.
  /// Null when [onReceive] opens the form anyway.
  final VoidCallback? onReceiveAdjust;

  /// Why the last receipt did not go through, in the buyer's words.
  final String? receiveError;
  final Future<bool> Function()? onPrint;
  final Future<OrderDocumentActionStatus> Function()? onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final receivable = onReceive != null;
    final error = receiveError;
    final tracked = [
      for (final line in order.lines)
        if (line.trackingMode.isTracked && line.receivableQuantity > 0) line,
    ];

    return PointyResultPanel(
      key: const ValueKey('purchase_result_recorded'),
      tone: error == null
          ? PointyResultTone.success
          : PointyResultTone.attention,
      title: saved
          ? l10n.purchaseResultSavedTitle
          : l10n.purchaseResultSubmittedTitle,
      subtitle: purchaseResultSubtitle(l10n, order),
      headline: PointyResultFigure(
        key: const ValueKey('purchase_result_total'),
        label: l10n.purchaseResultTotalLabel,
        value: formatMoney(order.total),
        color: colors.primaryStrong,
      ),
      footer: PurchaseResultButtons(
        primary: receivable
            ? PurchaseResultButton(
                name: 'receive',
                label: l10n.purchaseResultReceiveAction,
                icon: Icons.inventory_2_outlined,
                onPressed: onReceive!,
              )
            : PurchaseResultButton(
                name: 'done',
                label: doneLabel,
                icon: Icons.done_rounded,
                onPressed: onDone,
              ),
        secondary: receivable
            ? PurchaseResultButton(
                name: 'done',
                label: doneLabel,
                icon: Icons.schedule_rounded,
                onPressed: onDone,
              )
            : null,
        wrapPrimary: receivable
            ? (button) => TutorTarget(
                anchor: TutorAnchor.purchaseResultReceiveButton,
                child: button,
              )
            : (button) => TutorTarget(
                anchor: TutorAnchor.purchaseResultDoneButton,
                child: button,
              ),
        below: !receivable
            ? null
            : tracked.isNotEmpty
            ? Text(
                l10n.purchaseResultReceiveHint,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              )
            : onReceiveAdjust == null
            ? null
            : TextButton(
                key: const ValueKey('purchase_result_receive_adjust'),
                onPressed: onReceiveAdjust,
                child: Text(l10n.purchaseResultReceiveAdjustAction),
              ),
      ),
      children: [
        if (error != null)
          PointyDetailCallout(
            key: const ValueKey('purchase_result_receive_error'),
            icon: Icons.error_outline_rounded,
            tone: PointyCalloutTone.danger,
            title: l10n.purchaseResultReceiveFailedTitle,
            message: '$error\n${l10n.purchaseResultReceiveFailedBody}',
          )
        else if (receivable)
          PointyDetailCallout(
            key: const ValueKey('purchase_result_awaiting'),
            icon: Icons.local_shipping_outlined,
            tone: PointyCalloutTone.warning,
            title: l10n.purchaseResultAwaitingTitle,
            message: l10n.purchaseResultAwaitingBody,
          )
        else if (order.status == 'draft')
          PointyInlineMessage(
            key: const ValueKey('purchase_result_draft_note'),
            message: l10n.purchaseResultDraftNote,
            compact: true,
          ),
        if (receivable && tracked.isNotEmpty)
          PointyResultSection(
            title: l10n.purchaseResultDetailsTitle,
            icon: Icons.qr_code_scanner_rounded,
            child: PurchaseResultLines(
              key: const ValueKey('purchase_result_tracked_lines'),
              rows: [
                for (final line in tracked)
                  PurchaseResultLineRow(
                    name: _lineName(l10n, line),
                    detail: purchaseReceiptHint(
                      l10n,
                      line.trackingMode,
                      expiryRequired: line.tracksExpiry,
                    ),
                    quantity: _quantity(line, line.receivableQuantity),
                  ),
              ],
            ),
          ),
        if (onPrint case final onPrint?)
          PurchaseDocumentActions(onPrint: onPrint, onShare: onShare),
      ],
    );
  }
}

/// The goods are in. What went into stock, the stickers for what carries its
/// own number, and the order as paper.
class PurchaseReceivedView extends StatelessWidget {
  const PurchaseReceivedView({
    super.key,
    required this.order,
    required this.received,
    required this.orderLines,
    required this.doneLabel,
    required this.onDone,
    this.onPrintLabels,
    this.onPrint,
    this.onShare,
  });

  /// The order as the receipt left it.
  final PurchaseOrder order;

  /// What this receipt booked.
  final List<PurchaseReceiveLineDraft> received;

  /// The order's lines as they stood before it — their names and units.
  final List<PurchaseOrderLine> orderLines;
  final String doneLabel;
  final VoidCallback onDone;
  final VoidCallback? onPrintLabels;
  final Future<bool> Function()? onPrint;
  final Future<OrderDocumentActionStatus> Function()? onShare;

  /// How many received lines are listed before the rest fold into a count.
  static const int shownLines = 6;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final linesById = {for (final line in orderLines) line.id: line};
    final rows = <PurchaseResultLineRow>[
      for (final draft in received)
        if (linesById[draft.purchaseLineId] case final line?)
          PurchaseResultLineRow(
            name: _lineName(l10n, line),
            detail: [
              if (draft.quantityDamaged > 0)
                l10n.purchaseLineDamagedQuantity(
                  formatQuantity(draft.quantityDamaged),
                ),
              if (draft.quantityRejected > 0)
                l10n.purchaseLineRejectedQuantity(
                  formatQuantity(draft.quantityRejected),
                ),
            ].join(' • '),
            quantity: _quantity(line, draft.quantityReceived),
          ),
    ];
    final hidden = rows.length - shownLines;
    final onPrintLabels = this.onPrintLabels;

    return PointyResultPanel(
      key: const ValueKey('purchase_result_received'),
      tone: PointyResultTone.success,
      title: l10n.purchaseResultReceivedTitle,
      subtitle: purchaseResultSubtitle(l10n, order),
      footer: PurchaseResultButtons(
        primary: PurchaseResultButton(
          name: 'done',
          label: doneLabel,
          icon: Icons.done_rounded,
          onPressed: onDone,
        ),
        wrapPrimary: (button) => TutorTarget(
          anchor: TutorAnchor.purchaseResultDoneButton,
          child: button,
        ),
      ),
      children: [
        PointyResultSection(
          title: l10n.purchaseResultReceivedSection,
          icon: Icons.inventory_rounded,
          child: PurchaseResultLines(
            key: const ValueKey('purchase_result_received_lines'),
            rows: rows.take(shownLines).toList(growable: false),
            more: hidden > 0 ? l10n.purchaseResultMoreLines(hidden) : null,
          ),
        ),
        if (order.hasOpenReceiving)
          PointyInlineMessage(
            key: const ValueKey('purchase_result_still_open'),
            message: l10n.purchaseResultStillOpen,
            compact: true,
          ),
        if (onPrintLabels != null)
          PointyDetailCallout(
            key: const ValueKey('purchase_result_labels'),
            icon: Icons.qr_code_2_rounded,
            title: l10n.receiptLabelsTitle,
            message: l10n.purchaseResultLabelsBody,
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: FilledButton.tonal(
                key: const ValueKey('purchase_result_labels_action'),
                onPressed: onPrintLabels,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(l10n.receiptLabelsAction),
                ),
              ),
            ),
          ),
        if (onPrint case final onPrint?)
          PurchaseDocumentActions(onPrint: onPrint, onShare: onShare),
      ],
    );
  }
}

String _lineName(AppLocalizations l10n, PurchaseOrderLine line) =>
    line.displayName.isEmpty
    ? l10n.purchaseOrderUnknownProduct
    : line.displayName;

String _quantity(PurchaseOrderLine line, double quantity) {
  final unit = line.unitLabel.trim();
  final amount = formatQuantity(quantity);
  return unit.isEmpty ? amount : '$amount $unit';
}

/// One line of a purchase result's list.
class PurchaseResultLineRow {
  const PurchaseResultLineRow({
    required this.name,
    required this.quantity,
    this.detail = '',
  });

  final String name;
  final String quantity;

  /// A quieter second line: what receiving asks, what was damaged.
  final String detail;
}

/// A compact list of order lines, name first and quantity at the end.
class PurchaseResultLines extends StatelessWidget {
  const PurchaseResultLines({super.key, required this.rows, this.more});

  final List<PurchaseResultLineRow> rows;

  /// The count of lines not listed, said under the last one.
  final String? more;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, row) in rows.indexed)
            DecoratedBox(
              decoration: BoxDecoration(
                border: index == 0
                    ? null
                    : Border(top: BorderSide(color: colors.line)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colors.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (row.detail.isNotEmpty)
                            Text(
                              row.detail,
                              style: textTheme.bodySmall?.copyWith(
                                color: colors.mutedInk,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      row.quantity,
                      style: PointyTypography.numeric(
                        (textTheme.titleSmall ?? const TextStyle()).copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (more case final more?)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                more,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ),
        ],
      ),
    );
  }
}
