import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/job_refusal.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/register_session_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../register_sessions/views/open_register_session_dialog.dart';

/// Billing a job and taking its money — shared by the job screen, where the
/// counter asks for it, and the board, which asks for it on the way to the
/// job's last stage so nobody has to open the job to bill it.

/// Whether [capabilities] may bill [job]: nothing billed yet, not a job that
/// was called off, not a production batch — the shop's own stock, sold later
/// at the till — and someone who can take money.
bool canInvoiceJob(OperationsJob job, AuthorizationCapabilities capabilities) {
  return job.order == null &&
      job.status != OperationsJobStatus.cancelled &&
      job.jobType != OperationsJobType.production &&
      capabilities.canCheckoutSale;
}

/// How asking for a job's invoice ended.
enum JobInvoiceResult {
  /// The invoice was issued.
  invoiced,

  /// No invoice was issued here, and whatever was waiting on it may go on:
  /// the counter chose to, where the dialog offered it.
  skipped,

  /// Nothing was invoiced: somebody backed out, or a failure was already
  /// reported.
  cancelled,
}

class JobInvoiceOutcome {
  const JobInvoiceOutcome(this.result, {this.job});

  final JobInvoiceResult result;

  /// The job as the invoice left it. A kitchen order or a work order holds
  /// nothing of the customer's to hand back, so paying for it finishes it:
  /// this job may already be on its last stage.
  final OperationsJob? job;
}

/// Asks for [job]'s invoice and sends it through [invoice], answering on the
/// way the two refusals that are questions rather than failures: no drawer
/// open for the money, and a total above the price the customer approved.
///
/// [lead] says why the dialog opened when the counter did not ask for it
/// directly. [skipLabel] offers going on without an invoice; leave it null
/// wherever that is not an answer the caller can act on.
Future<JobInvoiceOutcome> runJobInvoice(
  BuildContext context, {
  required OperationsJob job,
  required Future<JobInvoiceAttempt> Function(JobInvoiceDraft draft) invoice,
  required AuthorizationCapabilities capabilities,
  RegisterSessionRepository? registerSessionRepository,
  ShopSettingsRepository? shopSettingsRepository,
  String? lead,
  String? skipLabel,
}) async {
  final answer = await showDialog<_JobInvoiceAnswer>(
    context: context,
    builder: (_) =>
        _JobInvoiceDialog(job: job, lead: lead, skipLabel: skipLabel),
  );
  if (answer == null || !context.mounted) {
    return const JobInvoiceOutcome(JobInvoiceResult.cancelled);
  }
  final draft = answer.draft;
  if (draft == null) {
    return const JobInvoiceOutcome(JobInvoiceResult.skipped);
  }
  final invoiced = await _JobInvoiceSubmission(
    invoice: invoice,
    capabilities: capabilities,
    registerSessionRepository: registerSessionRepository,
    shopSettingsRepository: shopSettingsRepository,
  ).send(context, draft);
  return invoiced == null
      ? const JobInvoiceOutcome(JobInvoiceResult.cancelled)
      : JobInvoiceOutcome(JobInvoiceResult.invoiced, job: invoiced);
}

/// Sending one invoice, and the questions its refusals raise.
class _JobInvoiceSubmission {
  const _JobInvoiceSubmission({
    required this.invoice,
    required this.capabilities,
    this.registerSessionRepository,
    this.shopSettingsRepository,
  });

  final Future<JobInvoiceAttempt> Function(JobInvoiceDraft draft) invoice;
  final AuthorizationCapabilities capabilities;

  /// Opens the person's own drawer when the invoice is refused for want of
  /// one. Without it the refusal is explained instead.
  final RegisterSessionRepository? registerSessionRepository;
  final ShopSettingsRepository? shopSettingsRepository;

  /// The invoiced job, or null when nothing was invoiced — and whatever went
  /// wrong has been said.
  Future<OperationsJob?> send(
    BuildContext context,
    JobInvoiceDraft draft, {
    bool drawerJustOpened = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final attempt = await invoice(draft);
    final invoiced = attempt.invoiced;
    if (!context.mounted) {
      return invoiced;
    }
    if (invoiced != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.jobInvoiceSuccess(invoiced.orderReceiptNumber)),
        ),
      );
      return invoiced;
    }

    // The money needs the person's own drawer and none is open — typically a
    // manager finishing a repair after the cashier closed up. Open it here and
    // send the same invoice again; the alternative was a job that could be
    // neither invoiced nor, because of that, handed back.
    final refusal = attempt.refusal;
    // Asked once: a drawer we have just opened that the server still cannot
    // see is a fault to report, not a question to repeat.
    if (refusal?.kind == JobRefusalKind.registerSessionRequired &&
        !drawerJustOpened) {
      final sessions = registerSessionRepository;
      if (sessions == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.paymentDrawerNotAllowedMessage)),
        );
        return null;
      }
      final opened = await openRegisterSessionForPayment(
        context,
        repository: sessions,
        capabilities: capabilities,
        shopSettingsRepository: shopSettingsRepository,
      );
      if (!opened || !context.mounted) {
        return null;
      }
      return send(context, draft, drawerJustOpened: true);
    }

    // Billing above what the customer agreed to is a real thing that happens —
    // the part turned out worse than the diagnosis said — so it is a question,
    // not a failure. Asking it here, with both numbers on screen, is the point
    // of the guard: someone has to have said yes.
    if (refusal?.kind == JobRefusalKind.overApprovedPrice) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.price_change_outlined),
          title: Text(l10n.jobOverQuoteTitle),
          content: Text(
            l10n.jobOverQuoteMessage(
              refusal!.approvedPrice,
              refusal.invoiceTotal,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.jobOverQuoteConfirm),
            ),
          ],
        ),
      );
      if (confirmed == true && context.mounted) {
        return send(
          context,
          JobInvoiceDraft(
            laborTotal: draft.laborTotal,
            payments: draft.payments,
            onCredit: draft.onCredit,
            dueDate: draft.dueDate,
            acknowledgeOverQuote: true,
          ),
        );
      }
      return null;
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.operationsActionError)));
    return null;
  }
}

/// The counter's answer to [_JobInvoiceDialog]: the invoice to issue, or —
/// where the dialog offered it — going on without one.
class _JobInvoiceAnswer {
  const _JobInvoiceAnswer.issue(JobInvoiceDraft this.draft);

  const _JobInvoiceAnswer.skip() : draft = null;

  /// Null when the counter chose to go on without an invoice.
  final JobInvoiceDraft? draft;
}

/// The invoice dialog: labour, payment method, and — for آجل — how much of the
/// total is landing in the drawer right now.
///
/// A widget rather than a `StatefulBuilder` in the calling method because the
/// two [TextEditingController]s have to outlive `showDialog`'s await.
/// `showDialog` completes when the route is *popped*, while the exit animation
/// is still running and both fields are still mounted; disposing the
/// controllers there means the next frame rebuilds a `TextField` against a dead
/// one, throwing "A TextEditingController was used after being disposed" and
/// then taking the screen down with a framework assertion. The State's
/// `dispose()` runs when the route is actually gone, which is the point.
///
/// The dialog's own answer-in-progress — the method, the credit switch, whether
/// the cashier has touched the amount-now box — moved in here with them.
class _JobInvoiceDialog extends StatefulWidget {
  const _JobInvoiceDialog({required this.job, this.lead, this.skipLabel});

  final OperationsJob job;

  /// Why the dialog opened, when the counter did not ask for it.
  final String? lead;

  /// The label of going on without an invoice; null leaves it out.
  final String? skipLabel;

  @override
  State<_JobInvoiceDialog> createState() => _JobInvoiceDialogState();
}

class _JobInvoiceDialogState extends State<_JobInvoiceDialog> {
  // A declined job bills its diagnosis fee and nothing else: no parts were
  // fitted, no work was done, and there is no labour to type.
  late final bool _feeOnly = widget.job.isDeclined;

  // Parts and services are already priced on the job; the labour box is for
  // the one-off amount that has no catalog line behind it.
  late final double _lineTotal = _feeOnly
      ? (widget.job.declineFee ?? 0)
      : widget.job.billableTotal;
  late final TextEditingController _laborController = TextEditingController(
    text: _feeOnly || widget.job.approvedPrice == null
        ? ''
        : (widget.job.approvedPrice! - _lineTotal)
              .clamp(0, double.infinity)
              .toStringAsFixed(2),
  );
  final TextEditingController _paidNowController = TextEditingController();
  var _method = PaymentMethod.cash;
  var _onCredit = false;
  // Seeded once the cashier switches to آجل, so the common "pay it all now
  // anyway" case does not need retyping the total.
  var _paidNowTouched = false;

  @override
  void dispose() {
    _laborController.dispose();
    _paidNowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final job = widget.job;
    final lead = widget.lead;
    final skipLabel = widget.skipLabel;
    final labor = _feeOnly
        ? 0.0
        : double.tryParse(_laborController.text.trim()) ?? 0;
    final total = _lineTotal + labor;
    final paidNow = _onCredit
        ? (double.tryParse(_paidNowController.text.trim()) ?? 0)
        : total;
    final balance = (total - paidNow).clamp(0.0, double.infinity);
    final needsCustomer = _onCredit && job.customer == null;
    final overpaid = paidNow > total;

    return AlertDialog(
      icon: const Icon(Icons.receipt_long_outlined),
      title: Text(_feeOnly ? l10n.jobCollectFeeTitle : l10n.jobInvoiceTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (lead != null) ...[
                PointyInlineMessage(
                  message: lead,
                  icon: Icons.flag_outlined,
                  compact: true,
                ),
                const SizedBox(height: 12),
              ],
              Text(
                _feeOnly
                    ? l10n.jobCollectFeeExplainer
                    : l10n.jobInvoiceExplainer,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_feeOnly)
                Text(l10n.jobCollectFeeAmountLabel(formatMoney(_lineTotal)))
              else ...[
                Text(
                  l10n.jobMaterialsTotalLabel(formatMoney(job.materialsTotal)),
                ),
                if (job.servicesTotal > 0)
                  Text(
                    '${l10n.jobInvoiceServicesLabel}: '
                    '${formatMoney(job.servicesTotal)}',
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _laborController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.jobLaborTotalLabel,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              const SizedBox(height: 12),
              SegmentedButton<PaymentMethod>(
                segments: [
                  ButtonSegment(
                    value: PaymentMethod.cash,
                    label: Text(l10n.paymentMethodCash),
                  ),
                  ButtonSegment(
                    value: PaymentMethod.card,
                    label: Text(l10n.paymentMethodCard),
                  ),
                  ButtonSegment(
                    value: PaymentMethod.transfer,
                    label: Text(l10n.paymentMethodTransfer),
                  ),
                ],
                selected: {_method},
                onSelectionChanged: (selection) {
                  setState(() => _method = selection.first);
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _onCredit,
                title: Text(l10n.jobInvoiceOnCreditLabel),
                subtitle: Text(l10n.jobInvoiceOnCreditExplainer),
                onChanged: (value) => setState(() {
                  _onCredit = value;
                  if (value && !_paidNowTouched) {
                    _paidNowController.text = total.toStringAsFixed(2);
                  }
                }),
              ),
              if (_onCredit) ...[
                TextField(
                  controller: _paidNowController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.jobInvoiceAmountNowLabel,
                  ),
                  onChanged: (_) => setState(() {
                    _paidNowTouched = true;
                  }),
                ),
                const SizedBox(height: 8),
                Text(l10n.jobBalanceDueLabel(formatMoney(balance))),
                if (needsCustomer)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: PointyInlineMessage.warning(
                      message: l10n.jobInvoiceNeedsCustomerForCredit,
                      icon: Icons.person_off_outlined,
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                l10n.jobInvoiceTotalLabel(formatMoney(total)),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.jobInvoiceNeedsRegister,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        if (skipLabel != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const _JobInvoiceAnswer.skip()),
            child: Text(skipLabel),
          ),
        FilledButton(
          onPressed: total <= 0 || needsCustomer || overpaid
              ? null
              : () => Navigator.of(context).pop(
                  _JobInvoiceAnswer.issue(
                    JobInvoiceDraft(
                      laborTotal: labor,
                      onCredit: _onCredit,
                      payments: [
                        if (paidNow > 0)
                          JobInvoicePayment(method: _method, amount: paidNow),
                      ],
                    ),
                  ),
                ),
          child: Text(
            _feeOnly ? l10n.jobCollectFeeButton : l10n.jobInvoiceButton,
          ),
        ),
      ],
    );
  }
}
