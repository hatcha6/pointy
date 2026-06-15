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
    final draft = await _showStartForm(context, widget.catalogRepository);
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

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final current = widget.viewModel.current;
        final history = widget.viewModel.sessions
            .where((session) => session.id != current?.id)
            .toList(growable: false);

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.stockCount,
            navigation: widget.navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.stockCountSessionsTitle),
            actions: [
              IconButton(
                tooltip: l10n.stockCountRefreshTooltip,
                onPressed: widget.viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: PointyDataList<StockCount>(
            items: history,
            isLoadingInitial: widget.viewModel.isLoading,
            isLoadingMore: widget.viewModel.isLoadingMore,
            hasMore: widget.viewModel.hasMore,
            hasError: widget.viewModel.hasLoadError,
            onLoadMore: widget.viewModel.loadMore,
            padding: AdaptiveSpacing.of(context).pagePadding,
            header: _Header(
              current: current,
              isStarting: widget.viewModel.isStarting,
              onResume: current == null ? null : () => _openCounting(current),
              onStartNew: _startNew,
            ),
            emptyBuilder: (context) => PointyEmptyState(
              icon: Icons.fact_check_outlined,
              title: l10n.stockCountEmpty,
            ),
            errorBuilder: (context) => PointyEmptyState(
              icon: Icons.error_outline,
              title: l10n.stockCountLoadError,
            ),
            itemBuilder: (context, session) => _SessionTile(
              session: session,
              onTap: () => _openHistory(session),
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
    required this.isStarting,
    required this.onResume,
    required this.onStartNew,
  });

  final StockCount? current;
  final bool isStarting;
  final VoidCallback? onResume;
  final VoidCallback onStartNew;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (current != null) ...[
            _ResumeCard(session: current!, onResume: onResume),
            SizedBox(height: spacing.md),
          ],
          FilledButton.icon(
            onPressed: isStarting ? null : onStartNew,
            icon: const Icon(Icons.add),
            label: Text(l10n.stockCountStartNew),
          ),
          SizedBox(height: spacing.lg),
          Text(
            l10n.stockCountHistoryTitle,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: spacing.sm),
        ],
      ),
    );
  }
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.session, required this.onResume});

  final StockCount session;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return PointyDetailSection(
      title: l10n.stockCountResume,
      icon: Icons.inventory_2_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.stockCountProgress(
              session.countedLineCount,
              session.expectedLineCount,
            ),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: spacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: session.progress,
              minHeight: 8,
              backgroundColor: colors.surfaceSunken,
            ),
          ),
          SizedBox(height: spacing.md),
          FilledButton.icon(
            onPressed: onResume,
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.stockCountResume),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.onTap});

  final StockCount session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final (label, color) = switch (session.status) {
      StockCountStatus.inProgress => (
        l10n.stockCountStatusInProgress,
        colors.warning,
      ),
      StockCountStatus.applied => (
        l10n.stockCountStatusApplied,
        colors.success,
      ),
      StockCountStatus.cancelled => (
        l10n.stockCountStatusCancelled,
        colors.mutedInk,
      ),
      StockCountStatus.unknown => (
        l10n.stockCountStatusCancelled,
        colors.mutedInk,
      ),
    };
    final scopeLabel = session.scope == StockCountScope.category
        ? l10n.stockCountScopeCategoryLabel(session.categoryName)
        : l10n.stockCountScopeFull;
    final created = session.createdAt;

    return ListTile(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(color: colors.line),
      ),
      title: Text('${session.countNumber} · $scopeLabel'),
      subtitle: Text(
        created == null
            ? l10n.stockCountMismatchCount(session.varianceLineCount)
            : '${formatDate(created)} · ${l10n.stockCountMismatchCount(session.varianceLineCount)}',
      ),
      trailing: PointyStatusPill(label: label, color: color),
      onTap: onTap,
    );
  }
}

Future<StockCountStartDraft?> _showStartForm(
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
              ),
              ButtonSegment(
                value: StockCountScope.category,
                label: Text(l10n.stockCountScopeCategory),
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
          FilledButton(
            onPressed: _submit,
            child: Text(l10n.stockCountStartButton),
          ),
        ],
      ),
    );
  }
}
