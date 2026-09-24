import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/operations_job.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// Asks why a repair is not going ahead, and what the diagnosis costs.
///
/// [suggestedFee] is the shop's usual diagnosis fee. It is offered for every
/// reason except "cannot be repaired", where charging for finding out the shop
/// could not help is the exception rather than the rule — until the cashier
/// types a fee themselves, which then stays whatever reason they pick.
Future<JobDeclineDraft?> showJobDeclineSheet(
  BuildContext context, {
  double? suggestedFee,
  JobDeclineReason initialReason = JobDeclineReason.price,
}) {
  return showAdaptiveModalBottomSheet<JobDeclineDraft>(
    context: context,
    builder: (_) => JobDeclineSheet(
      suggestedFee: suggestedFee,
      initialReason: initialReason,
    ),
  );
}

/// The content of [showJobDeclineSheet]. Public so the preview harness and
/// tests can render it without a route.
class JobDeclineSheet extends StatefulWidget {
  const JobDeclineSheet({
    super.key,
    this.suggestedFee,
    this.initialReason = JobDeclineReason.price,
  });

  final double? suggestedFee;
  final JobDeclineReason initialReason;

  @override
  State<JobDeclineSheet> createState() => _JobDeclineSheetState();
}

class _JobDeclineSheetState extends State<JobDeclineSheet> {
  // Owned here, not by the caller: disposing a caller's controller while the
  // sheet animates out rebuilds a field against a dead one.
  late final TextEditingController _feeController;
  final _noteController = TextEditingController();
  late JobDeclineReason _reason = widget.initialReason;
  var _feeTouched = false;

  @override
  void initState() {
    super.initState();
    _feeController = TextEditingController(text: _suggestedFeeFor(_reason));
  }

  @override
  void dispose() {
    _feeController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  String _suggestedFeeFor(JobDeclineReason reason) {
    final fee = widget.suggestedFee;
    if (fee == null || fee <= 0 || reason == JobDeclineReason.cannotRepair) {
      return '';
    }
    return fee.toStringAsFixed(2);
  }

  void _selectReason(JobDeclineReason reason) {
    setState(() {
      _reason = reason;
      if (!_feeTouched) {
        _feeController.text = _suggestedFeeFor(reason);
      }
    });
  }

  void _confirm() {
    Navigator.of(context).pop(
      JobDeclineDraft(
        reason: _reason,
        note: _noteController.text.trim(),
        fee: double.tryParse(_feeController.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.lg,
          spacing.xs,
          spacing.lg,
          spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.jobDeclineSheetTitle,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.jobDeclineSheetMessage,
              style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
            ),
            SizedBox(height: spacing.md),
            Text(l10n.jobDeclineReasonLabel, style: textTheme.labelLarge),
            SizedBox(height: spacing.xs),
            Wrap(
              spacing: spacing.xs,
              runSpacing: spacing.xs,
              children: [
                for (final reason in JobDeclineReason.values)
                  ChoiceChip(
                    label: Text(jobDeclineReasonLabel(l10n, reason)),
                    selected: _reason == reason,
                    onSelected: (_) => _selectReason(reason),
                  ),
              ],
            ),
            SizedBox(height: spacing.md),
            TextField(
              controller: _feeController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
              decoration: InputDecoration(
                labelText: l10n.jobDeclineFeeLabel,
                helperText: l10n.jobDeclineFeeHelper,
                helperMaxLines: 2,
                suffixText: currencySymbol,
              ),
              onChanged: (_) => _feeTouched = true,
            ),
            SizedBox(height: spacing.sm),
            TextField(
              controller: _noteController,
              maxLines: 2,
              decoration: InputDecoration(labelText: l10n.jobDeclineNoteLabel),
            ),
            SizedBox(height: spacing.lg),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelButton),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(Icons.assignment_return_outlined),
                  label: Text(l10n.jobDeclineConfirm),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// How each decline reason reads on screen.
String jobDeclineReasonLabel(AppLocalizations l10n, JobDeclineReason reason) {
  return switch (reason) {
    JobDeclineReason.price => l10n.jobDeclineReasonPrice,
    JobDeclineReason.declined => l10n.jobDeclineReasonDeclined,
    JobDeclineReason.cannotRepair => l10n.jobDeclineReasonCannotRepair,
    JobDeclineReason.noResponse => l10n.jobDeclineReasonNoResponse,
  };
}
