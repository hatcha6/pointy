import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/consignment.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';

/// The label a shop reads for each kind, responsibility and resolution.
///
/// One place, because these three enums appear on the report sheet, the
/// assessment sheet, the claims list and the unit timeline, and four
/// translations of *«ظرف قاهر»* would eventually disagree.
String consignmentIncidentKindLabel(AppLocalizations l10n, String kind) {
  return switch (kind) {
    ConsignmentIncidentKind.damaged => l10n.custodyKindDamaged,
    ConsignmentIncidentKind.lost => l10n.custodyKindLost,
    ConsignmentIncidentKind.stolen => l10n.custodyKindStolen,
    ConsignmentIncidentKind.destroyed => l10n.custodyKindDestroyed,
    ConsignmentIncidentKind.dispute => l10n.custodyKindDispute,
    _ => kind,
  };
}

String consignmentResponsibilityLabel(AppLocalizations l10n, String value) {
  return switch (value) {
    ConsignmentResponsibility.shop => l10n.custodyResponsibilityShop,
    ConsignmentResponsibility.consignor => l10n.custodyResponsibilityConsignor,
    ConsignmentResponsibility.thirdParty =>
      l10n.custodyResponsibilityThirdParty,
    ConsignmentResponsibility.forceMajeure =>
      l10n.custodyResponsibilityForceMajeure,
    ConsignmentResponsibility.undetermined =>
      l10n.custodyResponsibilityUndetermined,
    _ => value,
  };
}

String consignmentResolutionLabel(AppLocalizations l10n, String value) {
  return switch (value) {
    ConsignmentResolution.pending => l10n.custodyResolutionPending,
    ConsignmentResolution.paid => l10n.custodyResolutionPaid,
    ConsignmentResolution.replaced => l10n.custodyResolutionReplaced,
    ConsignmentResolution.waived => l10n.custodyResolutionWaived,
    ConsignmentResolution.insured => l10n.custodyResolutionInsured,
    ConsignmentResolution.noClaim => l10n.custodyResolutionNoClaim,
    _ => value,
  };
}

/// Write down what was found, the moment it was found (§6.2.2).
///
/// Responsibility is optional here on purpose. *«غير محدد»* is the honest
/// state on day one, and a form that made somebody choose a culprit before
/// they could record a broken camera would either delay the record or invent
/// the answer — and the whole point of this document is that the record does
/// not wait for the judgement.
Future<ConsignmentIncidentDraft?> showConsignmentIncidentSheet(
  BuildContext context,
) {
  return showModalBottomSheet<ConsignmentIncidentDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => const _IncidentSheet(),
  );
}

class _IncidentSheet extends StatefulWidget {
  const _IncidentSheet();

  @override
  State<_IncidentSheet> createState() => _IncidentSheetState();
}

class _IncidentSheetState extends State<_IncidentSheet> {
  final TextEditingController _narrative = TextEditingController();
  String _kind = ConsignmentIncidentKind.damaged;
  String? _responsibility;
  DateTime? _occurredOn;

  @override
  void dispose() {
    _narrative.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: spacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointySectionHeader(title: l10n.custodyIncidentReport),
              SizedBox(height: spacing.md),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: InputDecoration(
                  labelText: l10n.custodyIncidentKind,
                ),
                items: [
                  for (final kind in ConsignmentIncidentKind.all)
                    DropdownMenuItem(
                      value: kind,
                      child: Text(consignmentIncidentKindLabel(l10n, kind)),
                    ),
                ],
                onChanged: (value) => setState(() => _kind = value ?? _kind),
              ),
              SizedBox(height: spacing.md),
              TextField(
                controller: _narrative,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: l10n.custodyIncidentNarrative,
                  hintText: l10n.custodyIncidentNarrativeHint,
                ),
              ),
              SizedBox(height: spacing.md),
              DropdownButtonFormField<String>(
                initialValue: _responsibility,
                decoration: InputDecoration(
                  labelText: l10n.custodyIncidentResponsibility,
                  helperText: l10n.custodyIncidentUndeterminedNote,
                  helperMaxLines: 3,
                ),
                items: [
                  for (final value in ConsignmentResponsibility.all)
                    DropdownMenuItem(
                      value: value,
                      child: Text(consignmentResponsibilityLabel(l10n, value)),
                    ),
                ],
                onChanged: (value) => setState(() => _responsibility = value),
              ),
              SizedBox(height: spacing.md),
              _OccurredOnField(
                value: _occurredOn,
                onChanged: (value) => setState(() => _occurredOn = value),
              ),
              SizedBox(height: spacing.lg),
              FilledButton(
                onPressed: _narrative.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(context).pop(
                        ConsignmentIncidentDraft(
                          kind: _kind,
                          narrative: _narrative.text.trim(),
                          occurredOn: _occurredOn,
                          responsibility: _responsibility,
                        ),
                      ),
                child: Text(l10n.custodyIncidentReport),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// When it happened, which is often unknown — nobody saw the bag go.
/// ``discovered_at`` never is, and the backend stamps that itself.
class _OccurredOnField extends StatelessWidget {
  const _OccurredOnField({required this.value, required this.onChanged});

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InputDecorator(
      decoration: InputDecoration(labelText: l10n.custodyIncidentOccurredOn),
      child: Row(
        children: [
          Expanded(
            child: Text(
              value == null
                  ? '—'
                  : '${value!.year}-${value!.month.toString().padLeft(2, '0')}'
                        '-${value!.day.toString().padLeft(2, '0')}',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.event_outlined),
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: value ?? now,
                firstDate: DateTime(now.year - 5),
                lastDate: now,
              );
              if (picked != null) {
                onChanged(picked);
              }
            },
          ),
        ],
      ),
    );
  }
}
