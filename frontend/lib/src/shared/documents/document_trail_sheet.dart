import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../core/result.dart';
import '../../data/models/document_trail_event.dart';
import '../../data/repositories/document_trail_repository.dart';
import '../components/components.dart';
import '../date_formatters.dart';
import '../design/design.dart';
import '../responsive/responsive.dart';

/// Opens a document's own history: what happened to it, who did it, and why.
///
/// Deliberately the same sheet, the same shape and the same gestures as the
/// print-and-share history a user has already met — a person who has opened one
/// has learned to read the other. What it adds is the two things a print event
/// never has: the words someone typed as their reason, and what a correction
/// actually moved.
Future<void> showDocumentTrailSheet({
  required BuildContext context,
  required DocumentTrailRepository repository,
  required String documentType,
  required int documentId,
  required String documentNumber,
}) {
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.expanded,
    maxHeightFactor: 0.82,
    builder: (context) => DocumentTrailSheet(
      repository: repository,
      documentType: documentType,
      documentId: documentId,
      documentNumber: documentNumber,
    ),
  );
}

class DocumentTrailSheet extends StatefulWidget {
  const DocumentTrailSheet({
    super.key,
    required this.repository,
    required this.documentType,
    required this.documentId,
    required this.documentNumber,
  });

  final DocumentTrailRepository repository;
  final String documentType;
  final int documentId;
  final String documentNumber;

  @override
  State<DocumentTrailSheet> createState() => _DocumentTrailSheetState();
}

class _DocumentTrailSheetState extends State<DocumentTrailSheet> {
  List<DocumentTrailEvent> _events = const [];
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    final result = await widget.repository.loadTrail(
      documentType: widget.documentType,
      documentId: widget.documentId,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<DocumentTrailEvent>>(value: final events):
        setState(() {
          _events = events;
          _isLoading = false;
        });
      case Error<List<DocumentTrailEvent>>():
        setState(() {
          _events = const [];
          _isLoading = false;
          _hasError = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(spacing.md, 0, spacing.md, spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.documentTrailSheetTitle(widget.documentNumber),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: l10n.documentTrailRefreshTooltip,
                onPressed: _isLoading ? null : _load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Expanded(child: _content(l10n, spacing)),
        ],
      ),
    );
  }

  Widget _content(AppLocalizations l10n, AdaptiveSpacing spacing) {
    if (_isLoading) {
      return PointyLoadingArea(label: l10n.documentTrailLoading);
    }
    if (_hasError) {
      return PointyErrorState(
        title: l10n.documentTrailLoadError,
        action: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (_events.isEmpty) {
      return PointyEmptyState(
        icon: Icons.history_outlined,
        title: l10n.documentTrailEmptyTitle,
        message: l10n.documentTrailEmptyMessage,
      );
    }
    return ListView.separated(
      itemCount: _events.length,
      separatorBuilder: (context, index) => SizedBox(height: spacing.sm),
      itemBuilder: (context, index) =>
          DocumentTrailEventTile(event: _events[index]),
    );
  }
}

/// One entry in a document's history.
///
/// The reason is given its own quoted block rather than being folded into a
/// metadata line, because it is the one part written by a person: a cashier
/// reading back why an invoice was voided should find a sentence, not a field.
class DocumentTrailEventTile extends StatelessWidget {
  const DocumentTrailEventTile({super.key, required this.event});

  final DocumentTrailEvent event;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final accent = _accent(context, event.action);
    final radius = BorderRadius.circular(PointyRadii.card);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: radius,
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ActionMarker(icon: _icon(event.action), color: accent),
            SizedBox(width: spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _actionLabel(l10n, event.action),
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _meta(l10n),
                    style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                  ),
                  if (event.reason.trim().isNotEmpty) ...[
                    SizedBox(height: spacing.sm),
                    _ReasonBlock(reason: event.reason.trim()),
                  ],
                  if (event.changes.isNotEmpty) ...[
                    SizedBox(height: spacing.sm),
                    for (final change in event.changes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: _ChangeLine(change: change),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _meta(AppLocalizations l10n) {
    final actor = event.actorUsername?.trim() ?? '';
    return [
      if (event.createdAt != null) formatDateTime(event.createdAt!),
      l10n.documentTrailActorValue(
        actor.isEmpty ? l10n.documentTrailUnknownActor : actor,
      ),
    ].join(' • ');
  }
}

class _ActionMarker extends StatelessWidget {
  const _ActionMarker({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.12),
          context.pointyColors.surface,
        ),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}

class _ReasonBlock extends StatelessWidget {
  const _ReasonBlock({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.documentTrailReasonLabel,
            style: textTheme.labelSmall?.copyWith(
              color: colors.mutedInk,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(reason, style: textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ChangeLine extends StatelessWidget {
  const _ChangeLine({required this.change});

  final DocumentFieldChange change;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        Text(
          documentTrailFieldLabel(l10n, change.field),
          style: textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: colors.mutedInk,
          ),
        ),
        Text(
          l10n.documentTrailChangeValue(
            _value(l10n, change.from),
            _value(l10n, change.to),
          ),
          style: textTheme.bodySmall,
        ),
      ],
    );
  }

  String _value(AppLocalizations l10n, String raw) {
    final trimmed = raw.trim();
    return trimmed.isEmpty || trimmed == 'null'
        ? l10n.documentTrailEmptyValue
        : trimmed;
  }
}

/// The field names a correction can name, in the shop's words. Anything not
/// listed falls back to the column name — visible, ugly, and a prompt to add it
/// here rather than a silent blank.
String documentTrailFieldLabel(AppLocalizations l10n, String field) {
  return switch (field) {
    'amount' => l10n.documentTrailFieldAmount,
    'total' => l10n.documentTrailFieldTotal,
    'subtotal' => l10n.documentTrailFieldSubtotal,
    'discount_total' => l10n.documentTrailFieldDiscountTotal,
    'extra_discount_amount' => l10n.documentTrailFieldExtraDiscount,
    'quantity' => l10n.documentTrailFieldQuantity,
    'unit_cost' => l10n.documentTrailFieldUnitCost,
    'description' => l10n.documentTrailFieldDescription,
    'notes' => l10n.documentTrailFieldNotes,
    'reference' => l10n.documentTrailFieldReference,
    'customer' || 'customer_id' => l10n.documentTrailFieldCustomer,
    'supplier' || 'supplier_id' => l10n.documentTrailFieldSupplier,
    'category' || 'category_id' => l10n.documentTrailFieldCategory,
    'payment_method' => l10n.documentTrailFieldPaymentMethod,
    'spent_at' => l10n.documentTrailFieldSpentAt,
    'due_date' => l10n.documentTrailFieldDueDate,
    'supplier_invoice_number' => l10n.documentTrailFieldSupplierInvoiceNumber,
    'cancelled_total' => l10n.documentTrailFieldCancelledTotal,
    _ => field,
  };
}

String _actionLabel(AppLocalizations l10n, DocumentTrailAction action) {
  return switch (action) {
    DocumentTrailAction.created => l10n.documentTrailActionCreated,
    DocumentTrailAction.submitted => l10n.documentTrailActionSubmitted,
    DocumentTrailAction.edited => l10n.documentTrailActionEdited,
    DocumentTrailAction.corrected => l10n.documentTrailActionCorrected,
    DocumentTrailAction.cancelled => l10n.documentTrailActionCancelled,
    DocumentTrailAction.amended => l10n.documentTrailActionAmended,
    DocumentTrailAction.superseded => l10n.documentTrailActionSuperseded,
    DocumentTrailAction.unknown => l10n.documentTrailActionUnknown,
  };
}

IconData _icon(DocumentTrailAction action) {
  return switch (action) {
    DocumentTrailAction.created => Icons.note_add_outlined,
    DocumentTrailAction.submitted => Icons.task_alt,
    DocumentTrailAction.edited => Icons.edit_note_outlined,
    DocumentTrailAction.corrected => Icons.tune_outlined,
    DocumentTrailAction.cancelled => Icons.undo,
    DocumentTrailAction.amended => Icons.difference_outlined,
    DocumentTrailAction.superseded => Icons.arrow_outward,
    DocumentTrailAction.unknown => Icons.history_outlined,
  };
}

Color _accent(BuildContext context, DocumentTrailAction action) {
  final colors = context.pointyColors;
  return switch (action) {
    DocumentTrailAction.submitted => colors.success,
    DocumentTrailAction.cancelled => colors.danger,
    DocumentTrailAction.corrected ||
    DocumentTrailAction.edited => colors.warning,
    DocumentTrailAction.amended ||
    DocumentTrailAction.superseded => colors.primaryStrong,
    _ => colors.mutedInk,
  };
}
