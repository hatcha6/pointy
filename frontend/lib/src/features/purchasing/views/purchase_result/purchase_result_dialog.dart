import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../core/error_messages.dart';
import '../../../../core/result.dart';
import '../../../../data/models/purchase_submission.dart';
import '../../../../data/services/api_error_detail.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/tracking/unit_intake_permissions.dart';
import '../../../catalog/views/label_batch_print_sheet.dart';
import '../../view_models/purchase_order_documents.dart';
import '../../view_models/purchase_view_model.dart';
import '../purchase_order_details_screen.dart'
    show PurchaseReceiveForm, PurchaseReceiveFormState;
import '../receipt_labels.dart';
import 'purchase_result_buttons.dart';
import 'purchase_result_failure_view.dart';
import 'purchase_result_progress_view.dart';
import 'purchase_result_success_view.dart';

/// How the buyer left a purchase order's result.
sealed class PurchaseResultExit {
  const PurchaseResultExit();
}

/// The order is recorded — and received too, if the buyer did that here.
final class PurchaseResultDone extends PurchaseResultExit {
  const PurchaseResultDone();
}

/// Not recorded: the supplier's invoice number is taken, and the buyer wants
/// the order's settings to change it.
final class PurchaseResultEditInvoice extends PurchaseResultExit {
  const PurchaseResultEditInvoice();
}

/// Not recorded; back to the draft as it was.
final class PurchaseResultBackToDraft extends PurchaseResultExit {
  const PurchaseResultBackToDraft();
}

/// What the dialog sends: a new order, or a reopened one's edits.
enum PurchaseResultMode { submit, save }

/// Sends the purchase order and stays up through all of it: the progress,
/// then the result in the same dialog — the order as paper, and «استلام
/// البضاعة» for goods that are on the counter. Goods that carry identity are
/// received in the same dialog too: it turns into the receiving form, scan
/// sheets and all, so ordering, scanning and stocking are one sweep.
Future<PurchaseResultExit> showPurchaseResultDialog({
  required BuildContext context,
  required PurchaseViewModel viewModel,
  required PurchaseResultMode mode,
  PurchaseOrderDocuments? documents,
  UnitIntakePermissions permissions = UnitIntakePermissions.none,
  bool canReceive = true,
}) async {
  final exit = await showPointyResultDialog<PurchaseResultExit>(
    context: context,
    maxWidth: PurchaseResultDialog.formWidth,
    builder: (_) => PurchaseResultDialog(
      viewModel: viewModel,
      mode: mode,
      documents: documents,
      permissions: permissions,
      canReceive: canReceive,
    ),
  );
  return exit ?? const PurchaseResultBackToDraft();
}

class PurchaseResultDialog extends StatefulWidget {
  const PurchaseResultDialog({
    super.key,
    required this.viewModel,
    required this.mode,
    this.documents,
    this.permissions = UnitIntakePermissions.none,
    this.canReceive = true,
  });

  /// The receiving form's three quantity boxes need more room than an
  /// outcome does; every other stage keeps to [resultWidth].
  static const double formWidth = 680;
  static const double resultWidth = 520;

  final PurchaseViewModel viewModel;
  final PurchaseResultMode mode;
  final PurchaseOrderDocuments? documents;
  final UnitIntakePermissions permissions;

  /// Whether this buyer may receive goods at all.
  final bool canReceive;

  @override
  State<PurchaseResultDialog> createState() => _PurchaseResultDialogState();
}

enum _Stage {
  sending,
  costWarnings,
  failed,
  recorded,
  receiveForm,
  receiving,
  received,
}

class _PurchaseResultDialogState extends State<PurchaseResultDialog> {
  /// Read once: the draft is cleared the moment the order is recorded.
  late final String _sendingSubtitle = [
    widget.viewModel.selectedSupplier?.name.trim() ?? '',
    formatMoney(widget.viewModel.total),
  ].where((part) => part.isNotEmpty).join(' • ');

  final _form = GlobalKey<PurchaseReceiveFormState>();
  _Stage _stage = _Stage.sending;
  Object? _error;
  PurchaseOrder? _order;

  /// Whether the receiving form is mounted. It outlives the receipt's own
  /// progress, so a refused receipt goes back to the counts as typed.
  bool _formOpen = false;
  String? _receiveError;

  /// The receipt this dialog booked, and the lines it was read against.
  PurchaseReceiveDraft? _received;
  List<PurchaseOrderLine> _linesBeforeReceipt = const [];

  bool get _saving => widget.mode == PurchaseResultMode.save;

  @override
  void initState() {
    super.initState();
    // After the first frame: the send notifies the workspace the moment it
    // starts, and the dialog's own first build is not the time for that.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _send();
    });
  }

  Future<void> _send({bool acknowledgeCostWarnings = false}) async {
    if (_stage != _Stage.sending) {
      setState(() {
        _stage = _Stage.sending;
        _error = null;
      });
    }
    final viewModel = widget.viewModel;
    final Result<PurchaseOrder> result = switch (widget.mode) {
      PurchaseResultMode.submit => switch (await viewModel.submitDraft(
        acknowledgeCostWarnings: acknowledgeCostWarnings,
      )) {
        Ok(:final value) => Ok(value.order ?? _orderFromSummary(value)),
        Error(:final exception) => Error(exception),
      },
      PurchaseResultMode.save => await viewModel.saveDraft(
        acknowledgeCostWarnings: acknowledgeCostWarnings,
      ),
    };
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Ok(:final value):
          _order = value;
          _stage = _Stage.recorded;
        case Error(:final exception):
          _error = exception;
          _stage = viewModel.costWarnings.isEmpty
              ? _Stage.failed
              : _Stage.costWarnings;
      }
    });
  }

  /// A submission that came back without its order — never from the server,
  /// which always answers with one; this keeps the result honest regardless.
  static PurchaseOrder _orderFromSummary(PurchaseSubmission submission) {
    return PurchaseOrder(
      id: submission.orderId ?? 0,
      orderNumber: submission.draftNumber,
      status: submission.status,
      lineCount: submission.lineCount,
      total: submission.total,
      subtotal: submission.total,
      lines: const [],
      adjustments: const [],
      receipts: const [],
      canReturn: false,
      canRefund: false,
      canExchange: false,
    );
  }

  bool _receivable(PurchaseOrder order) =>
      widget.canReceive &&
      order.id > 0 &&
      order.hasOpenReceiving &&
      const {
        'submitted',
        'partial',
        'partially_received',
      }.contains(order.status);

  /// Everything as it came, at once — unless something has to be scanned or
  /// counted first, which opens the form instead.
  void _startReceipt(PurchaseOrder order, {bool adjust = false}) {
    if (adjust || order.receiptNeedsIdentifiers) {
      setState(() {
        _formOpen = true;
        _receiveError = null;
        _stage = _Stage.receiveForm;
      });
      return;
    }
    _receive(order, PurchaseReceiveDraft.everythingOpen(order));
  }

  void _confirmForm(PurchaseOrder order) {
    final draft = _form.currentState?.collect();
    if (draft != null) _receive(order, draft);
  }

  Future<void> _receive(PurchaseOrder order, PurchaseReceiveDraft draft) async {
    final fromForm = _stage == _Stage.receiveForm;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _receiveError = null;
      _stage = _Stage.receiving;
    });
    final result = await widget.viewModel.receiveCreatedOrder(order.id, draft);
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Ok(:final value):
          _linesBeforeReceipt = order.lines;
          _order = value;
          _received = draft;
          _formOpen = false;
          _stage = _Stage.received;
        case Error(:final exception):
          _receiveError = (apiStatusCode(exception) ?? 0) == 0
              ? l10n.checkoutResultCheckConnection
              : errorMessageFor(exception, l10n);
          _stage = fromForm ? _Stage.receiveForm : _Stage.recorded;
      }
    });
  }

  void _close(PurchaseResultExit exit) => Navigator.of(context).pop(exit);

  void _backToDraft() {
    widget.viewModel.clearCostWarnings();
    _close(const PurchaseResultBackToDraft());
  }

  /// What the barrier, Escape or the back button mean right now.
  void _onDismiss() {
    switch (_stage) {
      case _Stage.sending || _Stage.receiving:
        return;
      case _Stage.receiveForm:
        // Out of the form, not out of the result: the order is still there,
        // and so is the choice to receive it later.
        setState(() {
          _formOpen = false;
          _stage = _Stage.recorded;
        });
      case _Stage.costWarnings || _Stage.failed:
        _backToDraft();
      case _Stage.recorded || _Stage.received:
        _close(const PurchaseResultDone());
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final order = _order;
    final inForm = _stage == _Stage.receiveForm;

    return PopScope<PurchaseResultExit>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onDismiss();
      },
      child: AnimatedContainer(
        duration: reduceMotion ? Duration.zero : PointyMotion.standard,
        curve: PointyMotion.emphasizedCurve,
        constraints: BoxConstraints(
          maxWidth: inForm
              ? PurchaseResultDialog.formWidth
              : PurchaseResultDialog.resultWidth,
        ),
        child: Stack(
          children: [
            // Kept mounted, hidden, while the receipt it produced is sent:
            // an offstage child takes no room, and the counts and scans
            // survive a refusal.
            if (_formOpen && order != null)
              Offstage(
                offstage: !inForm,
                child: ExcludeFocus(
                  excluding: !inForm,
                  child: TickerMode(enabled: inForm, child: _formPanel(order)),
                ),
              ),
            if (!inForm)
              AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : PointyMotion.standard,
                layoutBuilder: (current, previous) =>
                    current ?? const SizedBox(),
                child: KeyedSubtree(
                  key: ValueKey(_stage),
                  child: _content(context),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final order = _order;
    final documents = widget.documents;
    switch (_stage) {
      case _Stage.sending:
        return ListenableBuilder(
          listenable: widget.viewModel,
          builder: (context, _) => PurchaseResultProgressView(
            title: _saving
                ? l10n.purchaseResultSavingTitle
                : l10n.purchaseResultWorkingTitle,
            subtitle: _sendingSubtitle,
            steps: _sendSteps(l10n),
            current: widget.viewModel.submitStep == PurchaseSubmitStep.submit
                ? 1
                : 0,
          ),
        );
      case _Stage.receiving:
        final steps = [..._sendSteps(l10n), l10n.purchaseResultStepReceive];
        return PurchaseResultProgressView(
          title: l10n.purchaseResultReceivingTitle,
          subtitle: purchaseResultSubtitle(l10n, order!),
          steps: steps,
          current: steps.length - 1,
        );
      case _Stage.costWarnings:
        return PurchaseCostWarningsView(
          warnings: widget.viewModel.costWarnings,
          onConfirm: () => _send(acknowledgeCostWarnings: true),
          onReview: _backToDraft,
        );
      case _Stage.failed:
        return PurchaseResultFailureView(
          error: _error!,
          saving: _saving,
          onRetry: _send,
          onEditInvoice: () => _close(const PurchaseResultEditInvoice()),
          onBack: _backToDraft,
        );
      case _Stage.recorded || _Stage.receiveForm:
        final receivable = _receivable(order!);
        return PurchaseRecordedView(
          order: order,
          saved: _saving,
          doneLabel: _saving
              ? l10n.checkoutResultDone
              : receivable
              ? l10n.purchaseResultReceiveLater
              : l10n.purchaseResultNewOrder,
          onDone: () => _close(const PurchaseResultDone()),
          onReceive: receivable ? () => _startReceipt(order) : null,
          onReceiveAdjust: receivable
              ? () => _startReceipt(order, adjust: true)
              : null,
          receiveError: _receiveError,
          onPrint: documents == null ? null : () => documents.print(order),
          onShare: documents == null ? null : () => documents.share(order),
        );
      case _Stage.received:
        final received = _received!.lines;
        final entries = receiptLabelEntries(
          orderLines: _linesBeforeReceipt,
          received: received,
          l10n: l10n,
        );
        final labels =
            documents != null && entries.any((entry) => entry.printable);
        return PurchaseReceivedView(
          order: order!,
          received: received,
          orderLines: _linesBeforeReceipt,
          doneLabel: _saving
              ? l10n.checkoutResultDone
              : l10n.purchaseResultNewOrder,
          onDone: () => _close(const PurchaseResultDone()),
          onPrintLabels: labels
              ? () => showLabelBatchPrintSheet(
                  context,
                  title: l10n.receiptLabelsTitle,
                  subtitle: l10n.receiptLabelsSubtitle,
                  entries: entries,
                  printingRepository: documents.printingRepository,
                )
              : null,
          onPrint: documents == null ? null : () => documents.print(order),
          onShare: documents == null ? null : () => documents.share(order),
        );
    }
  }

  List<String> _sendSteps(AppLocalizations l10n) => _saving
      ? [l10n.purchaseResultStepSave]
      : [l10n.purchaseResultStepCreate, l10n.purchaseResultStepSubmit];

  Widget _formPanel(PurchaseOrder order) {
    final l10n = AppLocalizations.of(context)!;
    final error = _receiveError;
    return PointyResultPanel(
      key: const ValueKey('purchase_result_receive_form'),
      tone: PointyResultTone.success,
      showMark: false,
      title: l10n.purchaseReceiveTitle,
      subtitle: l10n.purchaseResultFormSubtitle,
      footer: PurchaseResultButtons(
        primary: PurchaseResultButton(
          name: 'confirm_receive',
          label: l10n.purchaseResultConfirmReceive,
          icon: Icons.inventory_2_outlined,
          onPressed: () => _confirmForm(order),
        ),
        secondary: PurchaseResultButton(
          name: 'form_back',
          label: l10n.purchaseResultBack,
          icon: Icons.arrow_back_rounded,
          onPressed: _onDismiss,
        ),
        // The receiver is typing counts; Enter belongs to the fields.
        focusPrimary: false,
      ),
      children: [
        if (error != null)
          PointyInlineMessage.error(
            key: const ValueKey('purchase_result_receive_error'),
            message: '$error ${l10n.purchaseResultReceiveFailedBody}',
          ),
        PurchaseReceiveForm(
          key: _form,
          order: order,
          permissions: widget.permissions,
        ),
      ],
    );
  }
}
