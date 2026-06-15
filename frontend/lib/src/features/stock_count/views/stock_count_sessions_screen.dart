import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/product_category.dart';
import '../../../data/models/product_category_query.dart';
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_draft.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/stock_count_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/stock_count_sessions_view_model.dart';
import 'stock_count_counting_screen.dart';
import 'stock_count_reconciliation_screen.dart';
import 'stock_count_ui.dart';

class StockCountSessionsScreen extends StatefulWidget {
  const StockCountSessionsScreen({
    super.key,
    required this.viewModel,
    required this.stockCountRepository,
    required this.catalogRepository,
    required this.capabilities,
    required this.navigation,
  });

  final StockCountSessionsViewModel viewModel;
  final StockCountRepository stockCountRepository;
  final CatalogRepository catalogRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  State<StockCountSessionsScreen> createState() =>
      _StockCountSessionsScreenState();
}

class _StockCountSessionsScreenState extends State<StockCountSessionsScreen> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.load();
  }

  Future<void> _openCounting(StockCount session) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => StockCountCountingScreen(
          session: session,
          stockCountRepository: widget.stockCountRepository,
          catalogRepository: widget.catalogRepository,
          capabilities: widget.capabilities,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    await widget.viewModel.refreshAfterSession();
  }

  Future<void> _openHistory(StockCount session) async {
    if (session.isInProgress) {
      await _openCounting(session);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => StockCountReconciliationScreen(
          session: session,
          stockCountRepository: widget.stockCountRepository,
          capabilities: widget.capabilities,
        ),
      ),
    );
  }

  Future<void> _startNew() async {
    final draft = await showStockCountStartForm(
      context,
      widget.catalogRepository,
    );
    if (draft == null || !mounted) {
      return;
    }
    final session = await widget.viewModel.startCount(draft);
    if (!mounted) {
      return;
    }
    if (session == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.stockCountStartError),
          ),
        );
      return;
    }
    await _openCounting(session);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final vm = widget.viewModel;
        final current = vm.current;
        final history = vm.sessions
            .where((session) => session.id != current?.id)
            .toList(growable: false);

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.stockCount,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.stockCountSessionsTitle),
            isLoading: vm.isLoading,
            actions: [
              IconButton(
                tooltip: l10n.stockCountRefreshTooltip,
                onPressed: vm.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: PointyDataList<StockCount>(
              items: history,
              framed: false,
              isLoadingInitial: vm.isLoading,
              isLoadingMore: vm.isLoadingMore,
              hasMore: vm.hasMore,
              hasError: vm.hasLoadError,
              onLoadMore: vm.loadMore,
              padding: spacing.pagePadding,
              separatorBuilder: (_, _) => SizedBox(height: spacing.sm),
              header: _Header(
                current: current,
                hasHistory: history.isNotEmpty,
                isStarting: vm.isStarting,
                onResume: current == null ? null : () => _openCounting(current),
                onStartNew: _startNew,
              ),
              emptyBuilder: (context) =>
                  _HistoryEmpty(showFrame: current != null),
              errorBuilder: (context) => PointyEmptyState(
                icon: Icons.error_outline,
                title: l10n.stockCountLoadError,
              ),
              itemBuilder: (context, session) => _SessionHistoryTile(
                session: session,
                onTap: () => _openHistory(session),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.current,
    required this.hasHistory,
    required this.isStarting,
    required this.onResume,
    required this.onStartNew,
  });

  final StockCount? current;
  final bool hasHistory;
  final bool isStarting;
  final VoidCallback? onResume;
  final VoidCallback onStartNew;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (current != null) ...[
          _ActiveCountCard(session: current!, onResume: onResume),
          SizedBox(height: spacing.md),
          _StartCallout(isStarting: isStarting, onStartNew: onStartNew),
        ] else
          _StartHero(isStarting: isStarting, onStartNew: onStartNew),
        if (hasHistory) ...[
          SizedBox(height: spacing.xl),
          _HistoryHeader(),
          SizedBox(height: spacing.sm),
        ],
      ],
    );
  }
}

/// The resume hero: the in-progress count surfaced as the primary thing to do.
class _ActiveCountCard extends StatelessWidget {
  const _ActiveCountCard({required this.session, required this.onResume});

  final StockCount session;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _IconBadge(
                  icon: Icons.inventory_2_outlined,
                  color: colors.primaryStrong,
                ),
                SizedBox(width: spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: colors.warning,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.stockCountActiveTitle,
                            style: textTheme.labelMedium?.copyWith(
                              color: colors.warning,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        session.countNumber,
                        style: PointyTypography.numeric(
                          textTheme.titleLarge ?? const TextStyle(),
                        ).copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: spacing.sm),
                StockCountScopeChip(session: session),
              ],
            ),
            SizedBox(height: spacing.lg),
            StockCountProgressBar(
              counted: session.countedLineCount,
              total: session.expectedLineCount,
              progress: session.progress,
            ),
            SizedBox(height: spacing.lg),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: onResume,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.stockCountResume),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The welcome hero shown when there is no count in progress: explains the
/// route in one line and offers the single clear action.
class _StartHero extends StatelessWidget {
  const _StartHero({required this.isStarting, required this.onStartNew});

  final bool isStarting;
  final VoidCallback onStartNew;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: _IconBadge(
                icon: Icons.fact_check_outlined,
                color: PointyColors.primaryStrong,
                size: 64,
                iconSize: 32,
              ),
            ),
            SizedBox(height: spacing.md),
            Text(
              l10n.stockCountStartHeroTitle,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: spacing.sm),
            Text(
              l10n.stockCountStartHeroBody,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
            ),
            SizedBox(height: spacing.lg),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: isStarting ? null : onStartNew,
                icon: const Icon(Icons.add),
                label: Text(l10n.stockCountStartNew),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The quiet "start another count" affordance shown beneath the resume hero.
class _StartCallout extends StatelessWidget {
  const _StartCallout({required this.isStarting, required this.onStartNew});

  final bool isStarting;
  final VoidCallback onStartNew;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: isStarting ? null : onStartNew,
        icon: const Icon(Icons.add),
        label: Text(l10n.stockCountStartNew),
      ),
    );
  }
}

class _HistoryHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Icon(Icons.history, size: 20, color: colors.mutedInk),
        const SizedBox(width: 8),
        Text(
          l10n.stockCountHistoryTitle,
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty({required this.showFrame});

  /// When a count is already active the hero sits above, so the empty history
  /// note stays quiet; otherwise the welcome hero is the only thing above it.
  final bool showFrame;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsets.only(top: spacing.xl, bottom: spacing.lg),
      child: Column(
        children: [
          Icon(Icons.inventory_outlined, size: 32, color: colors.lineStrong),
          SizedBox(height: spacing.sm),
          Text(
            l10n.stockCountEmpty,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.mutedInk,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.stockCountHistoryEmptyHint,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}

class _SessionHistoryTile extends StatelessWidget {
  const _SessionHistoryTile({required this.session, required this.onTap});

  final StockCount session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final visual = StockCountStatusVisual.of(context, session.status);
    final created = session.createdAt;
    final meta = created == null
        ? visual.label
        : '${visual.label} · ${formatDate(created)}';

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Ink(
          decoration: BoxDecoration(
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(PointyRadii.card),
          ),
          child: Padding(
            padding: EdgeInsets.all(spacing.md),
            child: Row(
              children: [
                _IconBadge(icon: visual.icon, color: visual.color, size: 40),
                SizedBox(width: spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              session.countNumber,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PointyTypography.numeric(
                                textTheme.titleSmall ?? const TextStyle(),
                              ).copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          // The variance count is only meaningful once a count
                          // has been applied; a cancelled count never matched.
                          if (session.status == StockCountStatus.applied) ...[
                            SizedBox(width: spacing.sm),
                            _VarianceBadge(count: session.varianceLineCount),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: colors.mutedInk,
                              ),
                            ),
                          ),
                          SizedBox(width: spacing.sm),
                          StockCountScopeChip(session: session),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(width: spacing.xs),
                PointyDisclosureChevron(color: colors.mutedInk),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VarianceBadge extends StatelessWidget {
  const _VarianceBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    if (count == 0) {
      return PointyStatusPill(
        label: l10n.stockCountMatched,
        icon: Icons.check_circle_outline,
        color: colors.success,
      );
    }
    return PointyStatusPill(
      label: l10n.stockCountVarianceShort(count),
      icon: Icons.compare_arrows,
      color: colors.warning,
    );
  }
}

/// A soft, tinted circular icon badge used across the stock-count surfaces.
class _IconBadge extends StatelessWidget {
  const _IconBadge({
    required this.icon,
    required this.color,
    this.size = 48,
    this.iconSize,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: iconSize ?? size * 0.5),
    );
  }
}

Future<StockCountStartDraft?> showStockCountStartForm(
  BuildContext context,
  CatalogRepository catalogRepository,
) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveFormSurface<StockCountStartDraft>(
    context: context,
    title: l10n.stockCountStartTitle,
    builder: (context) => _StartForm(catalogRepository: catalogRepository),
  );
}

class _StartForm extends StatefulWidget {
  const _StartForm({required this.catalogRepository});

  final CatalogRepository catalogRepository;

  @override
  State<_StartForm> createState() => _StartFormState();
}

class _StartFormState extends State<_StartForm> {
  final TextEditingController _noteController = TextEditingController();
  StockCountScope _scope = StockCountScope.full;
  List<ProductCategory> _categories = const [];
  ProductCategory? _selectedCategory;
  bool _showCategoryError = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final result = await widget.catalogRepository.loadProductCategories(
      query: const ProductCategoryQuery(),
    );
    if (!mounted || result is! Ok<dynamic>) {
      return;
    }
    setState(() {
      _categories = (result as Ok).value.categories as List<ProductCategory>;
    });
  }

  void _submit() {
    if (_scope == StockCountScope.category && _selectedCategory == null) {
      setState(() => _showCategoryError = true);
      return;
    }
    Navigator.of(context).pop(
      StockCountStartDraft(
        scope: _scope,
        categoryId: _scope == StockCountScope.category
            ? _selectedCategory?.id
            : null,
        note: _noteController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SingleChildScrollView(
      padding: spacing.pagePadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.stockCountScopeLabel,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: spacing.sm),
          SegmentedButton<StockCountScope>(
            segments: [
              ButtonSegment(
                value: StockCountScope.full,
                label: Text(l10n.stockCountScopeFull),
                icon: const Icon(Icons.apps_outlined),
              ),
              ButtonSegment(
                value: StockCountScope.category,
                label: Text(l10n.stockCountScopeCategory),
                icon: const Icon(Icons.category_outlined),
              ),
            ],
            selected: {_scope},
            onSelectionChanged: (selection) {
              setState(() {
                _scope = selection.first;
                _showCategoryError = false;
              });
            },
          ),
          if (_scope == StockCountScope.category) ...[
            SizedBox(height: spacing.md),
            DropdownButtonFormField<ProductCategory>(
              initialValue: _selectedCategory,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.stockCountSelectCategory,
                errorText: _showCategoryError
                    ? l10n.stockCountSelectCategoryError
                    : null,
              ),
              items: [
                for (final category in _categories)
                  DropdownMenuItem(value: category, child: Text(category.name)),
              ],
              onChanged: (category) {
                setState(() {
                  _selectedCategory = category;
                  _showCategoryError = false;
                });
              },
            ),
          ],
          SizedBox(height: spacing.md),
          TextField(
            controller: _noteController,
            decoration: InputDecoration(labelText: l10n.stockCountNoteLabel),
            maxLength: 240,
          ),
          SizedBox(height: spacing.md),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.stockCountStartButton),
            ),
          ),
        ],
      ),
    );
  }
}
