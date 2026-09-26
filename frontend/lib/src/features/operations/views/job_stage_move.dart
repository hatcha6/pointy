import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/job_refusal.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/workflow.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// Moving a job to any stage of its workflow — the next one, three ahead, or
/// back to the bench when the test fails — shared by the board and the job
/// screen so both ask the same questions in the same order.
///
/// The server holds the gates; this only asks up front what a gate on the way
/// will want, so the counter answers a question instead of reading a refusal:
/// the price the customer approved when the move passes the approval stage,
/// and who is collecting when it hands the item back.

/// How a move ended.
enum JobMoveResult {
  /// The job is in the new stage.
  moved,

  /// Somebody backed out of one of the questions on the way.
  cancelled,

  /// The handover was refused because the job is not settled. The screen
  /// decides what to offer: invoice it there, or open the job to do so.
  unsettled,

  failed,
}

class JobMoveOutcome {
  const JobMoveOutcome(this.result, {this.collector = ''});

  final JobMoveResult result;

  /// Who is collecting the item, when the move hands it back — kept so a
  /// manager releasing it unsettled does not have to be asked again.
  final String collector;
}

/// The stages a move from [job]'s current stage to [target] enters or passes,
/// in order, and whether it goes forward. Null when either stage is not in
/// [stages] (a stale list), which callers treat as "cannot tell".
({bool forward, List<WorkflowStage> left, List<WorkflowStage> entered})?
jobStageSpan(
  OperationsJob job,
  List<WorkflowStage> stages,
  WorkflowStage target,
) {
  final current = stages.indexWhere((stage) => stage.id == job.currentStage);
  final destination = stages.indexWhere((stage) => stage.id == target.id);
  if (current < 0 || destination < 0) {
    // Without the whole workflow, the one move that can still be read is on
    // to the next stage — which the job itself names.
    if (job.nextStage?.id == target.id) {
      return (
        forward: true,
        left: [?job.currentStageDetails],
        entered: [target],
      );
    }
    return null;
  }
  if (current == destination) {
    return null;
  }
  final forward = destination > current;
  return (
    forward: forward,
    left: forward ? stages.sublist(current, destination) : const [],
    entered: forward ? stages.sublist(current + 1, destination + 1) : [target],
  );
}

/// Every stage of [stages], the current one marked, for the counter to pick
/// where the job actually is. Resolves to null when dismissed.
Future<WorkflowStage?> showJobStagePicker(
  BuildContext context, {
  required List<WorkflowStage> stages,
  required int currentStageId,
}) {
  return showAdaptiveModalBottomSheet<WorkflowStage>(
    context: context,
    builder: (sheetContext) =>
        _JobStagePicker(stages: stages, currentStageId: currentStageId),
  );
}

/// Moves [job] to [target], asking on the way only what the stages it passes
/// require. [recordApprovedPrice] saves the price the customer agreed;
/// [moveTo] asks the server to move the job.
Future<JobMoveOutcome> runJobStageMove(
  BuildContext context, {
  required OperationsJob job,
  required List<WorkflowStage> stages,
  required WorkflowStage target,
  required Future<bool> Function(double price) recordApprovedPrice,
  required Future<JobMoveAttempt> Function(
    WorkflowStage target,
    String collector,
  )
  moveTo,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final span = jobStageSpan(job, stages, target);
  if (span == null) {
    return const JobMoveOutcome(JobMoveResult.cancelled);
  }

  // Leaving — or jumping over — the stage where the customer approves the
  // price needs that price on record. Asked here, with the quote filled in,
  // rather than refused by the server after the tap.
  final passesApproval = span.left.any(
    (stage) => stage.requiresCustomerApproval,
  );
  if (passesApproval && job.approvedPrice == null) {
    final quoted = job.quotedPrice;
    final price = await showDialog<double>(
      context: context,
      builder: (_) => PointyNumberEntryDialog(
        icon: Icons.thumb_up_alt_outlined,
        title: l10n.jobApproveDialogTitle,
        message: l10n.jobMoveNeedsApprovalMessage,
        fieldLabel: l10n.jobApprovedPriceLabel,
        suffixText: currencySymbol,
        initialValue: quoted == null ? '' : quoted.toStringAsFixed(2),
        // Zero is a real answer: a warranty repair agreed at no charge.
        isValid: (value) => value >= 0,
        confirmLabel: l10n.jobApproveConfirm,
      ),
    );
    if (price == null || !context.mounted) {
      return const JobMoveOutcome(JobMoveResult.cancelled);
    }
    if (!await recordApprovedPrice(price)) {
      return const JobMoveOutcome(JobMoveResult.failed);
    }
    if (!context.mounted) {
      return const JobMoveOutcome(JobMoveResult.cancelled);
    }
  }

  // Handing the customer's property back is its own act, with its own
  // question, whether it is the next stage or the far end of a jump.
  var collector = '';
  final handsBack =
      job.handedOverAt == null &&
      span.entered.any((stage) => stage.releasesCustody);
  if (handsBack) {
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => PointyTextEntryDialog(
        icon: Icons.how_to_reg_outlined,
        title: l10n.jobHandoverDialogTitle,
        message: l10n.jobHandoverCollectorHint,
        fieldLabel: l10n.jobHandoverCollectorLabel,
        confirmLabel: l10n.jobHandoverConfirm,
      ),
    );
    if (answer == null || !context.mounted) {
      return const JobMoveOutcome(JobMoveResult.cancelled);
    }
    collector = answer.trim();
  }

  final attempt = await moveTo(target, collector);
  if (attempt.moved) {
    return JobMoveOutcome(JobMoveResult.moved, collector: collector);
  }
  if (attempt.refusal?.kind == JobRefusalKind.settlementRequired) {
    return JobMoveOutcome(JobMoveResult.unsettled, collector: collector);
  }
  return JobMoveOutcome(JobMoveResult.failed, collector: collector);
}

class _JobStagePicker extends StatelessWidget {
  const _JobStagePicker({required this.stages, required this.currentStageId});

  final List<WorkflowStage> stages;
  final int currentStageId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final currentIndex = stages.indexWhere(
      (stage) => stage.id == currentStageId,
    );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.jobMoveToStageAction,
                    style: textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.jobMoveToStageHint,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
            for (var index = 0; index < stages.length; index++)
              _StageOption(
                stage: stages[index],
                isCurrent: index == currentIndex,
                isDone: currentIndex >= 0 && index < currentIndex,
                onTap: () => Navigator.of(context).pop(stages[index]),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _StageOption extends StatelessWidget {
  const _StageOption({
    required this.stage,
    required this.isCurrent,
    required this.isDone,
    required this.onTap,
  });

  final WorkflowStage stage;
  final bool isCurrent;
  final bool isDone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final (icon, color) = isCurrent
        ? (Icons.radio_button_checked, colors.primary)
        : isDone
        ? (Icons.check_circle, colors.success)
        : (Icons.radio_button_unchecked, colors.mutedInk);

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        stage.name,
        style: isCurrent ? const TextStyle(fontWeight: FontWeight.w800) : null,
      ),
      subtitle: isCurrent ? Text(l10n.jobStageCurrentBadge) : null,
      trailing: stage.releasesCustody
          ? Icon(Icons.how_to_reg_outlined, color: colors.mutedInk)
          : null,
      enabled: !isCurrent,
      onTap: isCurrent ? null : onTap,
    );
  }
}
