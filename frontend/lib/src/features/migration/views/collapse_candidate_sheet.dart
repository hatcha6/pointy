import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/migration_collapse.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'collapse_reasons.dart';

/// One row, opened for a person who disagrees with the parser.
///
/// Deliberately small: the four things a human can settle better than a regular
/// expression — which product this is, which number is its identifier, which
/// options it has, and whether it is still on the shelf — plus the one escape
/// hatch that matters, which is "leave it alone".
Future<Map<String, Object?>?> showCollapseCandidateSheet(
  BuildContext context, {
  required CollapseCandidate candidate,
}) {
  return showModalBottomSheet<Map<String, Object?>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _CollapseCandidateSheet(candidate: candidate),
  );
}

class _CollapseCandidateSheet extends StatefulWidget {
  const _CollapseCandidateSheet({required this.candidate});

  final CollapseCandidate candidate;

  @override
  State<_CollapseCandidateSheet> createState() =>
      _CollapseCandidateSheetState();
}

class _CollapseCandidateSheetState extends State<_CollapseCandidateSheet> {
  late final TextEditingController _stem;
  late final TextEditingController _identifier;
  late final TextEditingController _storage;
  late final TextEditingController _colour;
  late bool _keep;
  late bool _sold;

  @override
  void initState() {
    super.initState();
    final candidate = widget.candidate;
    _stem = TextEditingController(text: candidate.stem);
    _identifier = TextEditingController(text: candidate.identifier);
    _storage = TextEditingController(text: candidate.options['storage'] ?? '');
    _colour = TextEditingController(text: candidate.options['colour'] ?? '');
    _keep = !candidate.isCollapsing;
    _sold = candidate.isSold;
  }

  @override
  void dispose() {
    _stem.dispose();
    _identifier.dispose();
    _storage.dispose();
    _colour.dispose();
    super.dispose();
  }

  /// Only what actually changed, so an untouched field is never re-sent as an
  /// edit — the server marks a row as edited by hand the moment it is written.
  Map<String, Object?> _changes() {
    final candidate = widget.candidate;
    final changes = <String, Object?>{};
    final decision = _keep ? 'keep' : 'collapse';
    if (decision != candidate.decision) changes['decision'] = decision;
    if (_stem.text.trim() != candidate.stem) {
      changes['stem'] = _stem.text.trim();
    }
    if (_identifier.text.trim() != candidate.identifier) {
      changes['identifier'] = _identifier.text.trim();
    }
    final options = <String, String>{
      if (_storage.text.trim().isNotEmpty) 'storage': _storage.text.trim(),
      if (_colour.text.trim().isNotEmpty) 'colour': _colour.text.trim(),
    };
    if (!_sameOptions(options, candidate.options)) changes['options'] = options;
    final status = _sold ? 'sold' : 'in_stock';
    if (status != candidate.unitStatus) changes['unit_status'] = status;
    return changes;
  }

  bool _sameOptions(Map<String, String> left, Map<String, String> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final candidate = widget.candidate;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.collapseEditTitle, style: theme.textTheme.titleMedium),
            SizedBox(height: spacing.xs),
            Text(
              candidate.sourceName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
            if (candidate.reasons.isNotEmpty) ...[
              SizedBox(height: spacing.sm),
              Wrap(
                spacing: spacing.xs,
                runSpacing: spacing.xs,
                children: [
                  for (final reason in candidate.reasons)
                    _ReasonChip(label: collapseReasonLabel(l10n, reason)),
                ],
              ),
            ],
            SizedBox(height: spacing.md),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _keep,
              onChanged: (value) => setState(() => _keep = value),
              title: Text(l10n.collapseEditKeep),
            ),
            if (!_keep) ...[
              SizedBox(height: spacing.sm),
              TextField(
                controller: _stem,
                decoration: InputDecoration(
                  labelText: l10n.collapseEditProductName,
                  helperText: l10n.collapseEditProductNameHelp,
                  helperMaxLines: 2,
                ),
              ),
              SizedBox(height: spacing.sm),
              TextField(
                controller: _identifier,
                decoration: InputDecoration(
                  labelText: l10n.collapseEditIdentifier,
                ),
              ),
              SizedBox(height: spacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _storage,
                      decoration: InputDecoration(
                        labelText: l10n.collapseEditStorage,
                      ),
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _colour,
                      decoration: InputDecoration(
                        labelText: l10n.collapseEditColour,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: spacing.sm),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(l10n.collapseUnitInStock),
                    icon: const Icon(Icons.inventory_2_outlined),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(l10n.collapseUnitSold),
                    icon: const Icon(Icons.receipt_long_outlined),
                  ),
                ],
                selected: {_sold},
                onSelectionChanged: (values) =>
                    setState(() => _sold = values.first),
              ),
            ],
            SizedBox(height: spacing.md),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_changes()),
              child: Text(l10n.collapseEditSave),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReasonChip extends StatelessWidget {
  const _ReasonChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: colors.warning),
      ),
    );
  }
}
