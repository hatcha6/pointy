import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/query_controls/query_filter_sheet.dart';
import '../models/learning_guide.dart';
import '../models/learning_query.dart';
import 'learning_presentation.dart';

/// Filters and sort for the learning catalogue, in the shared sheet the
/// products, invoices, purchase orders and discounts lists all use.
class LearningFilterSheet extends StatefulWidget {
  const LearningFilterSheet({super.key, required this.query});

  final LearningQuery query;

  @override
  State<LearningFilterSheet> createState() => _LearningFilterSheetState();
}

class _LearningFilterSheetState extends State<LearningFilterSheet> {
  late LearningTrack? _track = widget.query.track;
  late var _level = widget.query.level;
  late var _kind = widget.query.kind;
  late var _audience = widget.query.audience;
  late var _progress = widget.query.progress;
  late var _sort = widget.query.sort;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryFilterSheet(
      title: l10n.filtersSheetTitle,
      resetLabel: l10n.resetFiltersButton,
      applyLabel: l10n.applyFiltersButton,
      onReset: _reset,
      onApply: _apply,
      children: [
        const SizedBox(height: 22),
        QueryFilterSection(
          title: l10n.learningTrackFilterTitle,
          children: [
            QueryFilterOptionTile(
              label: l10n.learningFilterAll,
              icon: Icons.all_inclusive,
              isSelected: _track == null,
              onTap: () => setState(() => _track = null),
            ),
            for (final track in LearningTrack.values)
              QueryFilterOptionTile(
                label: learningTrackLabel(l10n, track),
                icon: learningTrackIcon(track),
                isSelected: _track == track,
                onTap: () => setState(() => _track = track),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.learningLevelFilterTitle,
          children: [
            for (final level in LearningLevelFilter.values)
              QueryFilterOptionTile(
                label: learningLevelFilterLabel(l10n, level),
                icon: learningLevelFilterIcon(level),
                isSelected: _level == level,
                onTap: () => setState(() => _level = level),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.learningKindFilterTitle,
          children: [
            for (final kind in LearningKindFilter.values)
              QueryFilterOptionTile(
                label: learningKindFilterLabel(l10n, kind),
                icon: learningKindFilterIcon(kind),
                isSelected: _kind == kind,
                onTap: () => setState(() => _kind = kind),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.learningAudienceFilterTitle,
          children: [
            for (final audience in LearningAudienceFilter.values)
              QueryFilterOptionTile(
                label: learningAudienceFilterLabel(l10n, audience),
                icon: learningAudienceFilterIcon(audience),
                isSelected: _audience == audience,
                onTap: () => setState(() => _audience = audience),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.learningProgressFilterTitle,
          children: [
            for (final progress in LearningProgressFilter.values)
              QueryFilterOptionTile(
                label: learningProgressFilterLabel(l10n, progress),
                icon: learningProgressFilterIcon(progress),
                isSelected: _progress == progress,
                onTap: () => setState(() => _progress = progress),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.learningSortTitle,
          children: [
            for (final sort in LearningSort.values)
              QueryFilterOptionTile(
                label: learningSortLabel(l10n, sort),
                icon: learningSortIcon(sort),
                isSelected: _sort == sort,
                onTap: () => setState(() => _sort = sort),
              ),
          ],
        ),
      ],
    );
  }

  void _reset() {
    setState(() {
      _track = null;
      _level = LearningLevelFilter.all;
      _kind = LearningKindFilter.all;
      _audience = LearningAudienceFilter.all;
      _progress = LearningProgressFilter.all;
      _sort = LearningSort.recommended;
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      LearningQuery(
        search: widget.query.search,
        track: _track,
        level: _level,
        kind: _kind,
        audience: _audience,
        progress: _progress,
        sort: _sort,
      ),
    );
  }
}
