import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../models/learning_guide.dart';
import '../view_models/learning_view_model.dart';
import 'learning_guide_card.dart';
import 'learning_guide_view.dart';
import 'learning_presentation.dart';
import 'learning_query_controls.dart';

/// The learning catalogue: every guide, searchable, filterable and sortable.
class LearningScreen extends StatefulWidget {
  const LearningScreen({
    super.key,
    required this.viewModel,
    required this.navigation,
  });

  final LearningViewModel viewModel;
  final AppNavigation navigation;

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  LearningViewModel get viewModel => widget.viewModel;

  LearningGuide? _selected;

  @override
  void initState() {
    super.initState();
    viewModel.initialize();
    viewModel.restoreProgress();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyScaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: AppNavigationDestination.learning,
        navigation: widget.navigation,
      ),
      appBar: AppBar(
        leading: const PointyNavigationMenuButton(),
        title: Text(l10n.learningTitle),
      ),
      body: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) {
          return MasterDetailLayout(
            listPaneBuilder: (paneContext, isDualPane) => _LearningCatalogue(
              viewModel: viewModel,
              selected: isDualPane ? _selected : null,
              onOpenGuide: (guide) => isDualPane
                  ? setState(() => _selected = guide)
                  : _pushGuide(context, guide),
            ),
            placeholder: PointyEmptyState(
              icon: Icons.school_outlined,
              title: l10n.learningSelectGuidePlaceholder,
            ),
            detailPane: _selected == null
                ? null
                : LearningGuideView(
                    key: ValueKey('learning_guide_${_selected!.id}'),
                    guide: _selected!,
                    viewModel: viewModel,
                    onOpenGuide: (guide) => setState(() => _selected = guide),
                    onOpenDestination: _openDestination,
                  ),
          );
        },
      ),
    );
  }

  Future<void> _pushGuide(BuildContext context, LearningGuide guide) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => LearningGuideScreen(
          guide: guide,
          viewModel: viewModel,
          onOpenDestination: _openDestination,
        ),
      ),
    );
  }

  void _openDestination(AppNavigationDestination destination) {
    if (!widget.navigation.isDestinationAvailable(destination)) {
      return;
    }
    widget.navigation.navigateTo(
      context,
      destination,
      from: AppNavigationDestination.learning,
    );
  }
}

/// A single guide as its own route — the phone-width counterpart of the
/// catalogue's detail pane.
class LearningGuideScreen extends StatelessWidget {
  const LearningGuideScreen({
    super.key,
    required this.guide,
    required this.viewModel,
    this.onOpenDestination,
  });

  final LearningGuide guide;
  final LearningViewModel viewModel;
  final ValueChanged<AppNavigationDestination>? onOpenDestination;

  @override
  Widget build(BuildContext context) {
    return PointyScaffold(
      appBar: AppBar(title: Text(guide.title)),
      body: LearningGuideView(
        guide: guide,
        viewModel: viewModel,
        onOpenGuide: (next) => Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (context) => LearningGuideScreen(
              guide: next,
              viewModel: viewModel,
              onOpenDestination: onOpenDestination,
            ),
          ),
        ),
        onOpenDestination: onOpenDestination,
      ),
    );
  }
}

class _LearningCatalogue extends StatelessWidget {
  const _LearningCatalogue({
    required this.viewModel,
    required this.selected,
    required this.onOpenGuide,
  });

  final LearningViewModel viewModel;
  final LearningGuide? selected;
  final ValueChanged<LearningGuide> onOpenGuide;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final results = viewModel.results;

    return ListView(
      padding: spacing.pagePadding,
      children: [
        _CatalogueHeader(viewModel: viewModel),
        SizedBox(height: spacing.md),
        LearningQueryControls(
          query: viewModel.query,
          onSearchChanged: viewModel.setSearch,
          onQueryChanged: viewModel.setQuery,
        ),
        SizedBox(height: spacing.sm),
        _TrackChips(viewModel: viewModel),
        SizedBox(height: spacing.sm),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 2),
          child: Text(
            l10n.learningResultsCount(results.length),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
        ),
        SizedBox(height: spacing.sm),
        if (results.isEmpty)
          QueryEmptyState(
            icon: Icons.school_outlined,
            search: viewModel.query.search,
            hasFilters: viewModel.query.hasFilters,
            emptyTitle: l10n.learningEmptyTitle,
            onClear: viewModel.clearFilters,
          )
        else
          for (final (index, guide) in results.indexed) ...[
            if (index > 0) SizedBox(height: spacing.sm),
            LearningGuideCard(
              guide: guide,
              isFinished: viewModel.isFinished(guide.id),
              isSelected: selected?.id == guide.id,
              onTap: () => onOpenGuide(guide),
            ),
          ],
        SizedBox(height: spacing.xl),
      ],
    );
  }
}

class _CatalogueHeader extends StatelessWidget {
  const _CatalogueHeader({required this.viewModel});

  final LearningViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailHero(
      icon: Icons.school_outlined,
      title: l10n.learningHeaderTitle,
      description: l10n.learningHeaderSubtitle,
      pills: [
        PointyHeroPill(
          label: l10n.learningProgressValue(
            viewModel.finishedCount,
            viewModel.libraryCount,
          ),
          icon: Icons.check_circle_outline,
        ),
      ],
    );
  }
}

/// Quick track chips above the list — the same shortcut the POS catalogue gives
/// for pinned categories, for the filter people reach for most.
class _TrackChips extends StatelessWidget {
  const _TrackChips({required this.viewModel});

  final LearningViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selected = viewModel.query.track;

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: ChoiceChip(
              label: Text(l10n.learningFilterAll),
              selected: selected == null,
              onSelected: (_) => viewModel.selectTrack(null),
            ),
          ),
          for (final track in LearningTrack.values)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                avatar: Icon(learningTrackIcon(track), size: 18),
                label: Text(learningTrackLabel(l10n, track)),
                selected: selected == track,
                onSelected: (isSelected) =>
                    viewModel.selectTrack(isSelected ? track : null),
              ),
            ),
        ],
      ),
    );
  }
}
