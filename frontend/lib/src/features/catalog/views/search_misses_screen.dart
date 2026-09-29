import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/search_miss.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_denied_view.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../operations/views/variant_picker_sheet.dart';
import '../view_models/search_misses_view_model.dart';
import 'search_miss_row.dart';

/// «عمليات بحث بلا نتائج»: the words people searched the catalogue for and
/// found nothing, most typed first.
///
/// Each one is a product the shop sells under a name its catalogue does not
/// know, or a slip. The owner says which product a word meant — the server
/// keeps the word as a name of it, so the next search finds it — or sets the
/// word aside.
class SearchMissesScreen extends StatelessWidget {
  const SearchMissesScreen({
    super.key,
    required this.viewModel,
    required this.catalogRepository,
    required this.navigation,
    this.showBackButton = false,
    this.now,
  });

  final SearchMissesViewModel viewModel;

  /// Searched by the product picker behind «هذا المنتج…».
  final CatalogRepository catalogRepository;
  final AppNavigation navigation;

  /// Opened from the catalog rather than from the navigation: back returns
  /// there instead of the menu opening.
  final bool showBackButton;

  /// Injectable so a preview or a test renders a fixed "today".
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.searchMisses,
            navigation: navigation,
          ),
          appBar: PointyAppBar(
            leading: showBackButton
                ? IconButton(
                    tooltip: l10n.backTooltip,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  )
                : const PointyNavigationMenuButton(),
            title: Text(l10n.searchMissesTitle),
            isLoading: viewModel.isLoading,
            actions: [
              IconButton(
                tooltip: l10n.searchMissesRefreshTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: ProductChangeGuard(
            capabilities: navigation.capabilities,
            fallback: const AuthorizationDeniedView(),
            child: AdaptiveMaxWidth(
              width: AppContentWidth.detail,
              child: _body(context, l10n),
            ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    final filter = viewModel.filter;
    final showHint =
        filter == SearchMissFilter.open && viewModel.misses.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.pageHorizontal,
            spacing.pageVertical,
            spacing.pageHorizontal,
            spacing.sm,
          ),
          child: _FilterChips(
            selected: filter,
            onSelected: viewModel.setFilter,
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: viewModel.load,
            child: PointyDataList<SearchMiss>(
              items: viewModel.misses,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              hasMore: viewModel.hasMore,
              onLoadMore: viewModel.loadMore,
              loadMoreFailed: viewModel.loadMoreFailed,
              loadMoreErrorMessage: l10n.searchMissesLoadError,
              hasError: viewModel.hasError,
              framed: false,
              padding: EdgeInsetsDirectional.fromSTEB(
                spacing.pageHorizontal,
                0,
                spacing.pageHorizontal,
                spacing.pageVertical,
              ),
              separatorBuilder: (_, _) => SizedBox(height: spacing.xs),
              header: showHint ? _Hint(spacing: spacing) : null,
              errorBuilder: (context) => PointyErrorState(
                icon: Icons.cloud_off_outlined,
                title: l10n.searchMissesLoadError,
                action: FilledButton.tonalIcon(
                  onPressed: viewModel.load,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retryButton),
                ),
              ),
              emptyBuilder: (context) => _empty(l10n, filter),
              itemBuilder: (context, miss) => SearchMissRow(
                miss: miss,
                busy: viewModel.isBusy(miss),
                markDismissed: filter == SearchMissFilter.all,
                now: now,
                onResolve: () => _resolve(context, miss),
                onDismiss: () => _dismiss(context, miss),
                onReopen: () => _reopen(context, miss),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _empty(AppLocalizations l10n, SearchMissFilter filter) {
    return switch (filter) {
      SearchMissFilter.resolved => PointyEmptyState(
        icon: Icons.link,
        title: l10n.searchMissesEmptyResolved,
      ),
      SearchMissFilter.dismissed => PointyEmptyState(
        icon: Icons.do_not_disturb_on_outlined,
        title: l10n.searchMissesEmptyDismissed,
      ),
      SearchMissFilter.open || SearchMissFilter.all => PointyEmptyState(
        icon: Icons.manage_search,
        title: l10n.searchMissesEmptyTitle,
        message: l10n.searchMissesEmptyMessage,
      ),
    };
  }

  /// Asks which product the word meant, then teaches it to the catalogue.
  Future<void> _resolve(BuildContext context, SearchMiss miss) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final variant = await showVariantPickerSheet(
      context,
      catalogRepository: catalogRepository,
      title: l10n.searchMissPickProductTitle(_isolated(miss.term)),
      emptyMessage: l10n.searchMissPickProductEmpty,
    );
    if (variant == null) {
      return;
    }
    final outcome = await viewModel.resolve(miss, productId: variant.productId);
    _announce(messenger, switch (outcome) {
      SearchMissActionOutcome.done => l10n.searchMissResolvedMessage(
        _isolated(miss.term),
        _isolated(variant.productLabel),
      ),
      SearchMissActionOutcome.productRefused => l10n.searchMissProductRefused,
      SearchMissActionOutcome.failed => l10n.searchMissActionError,
      SearchMissActionOutcome.busy => null,
    });
  }

  /// Sets the word aside, with an undo: dismissing is one tap and a slip of
  /// the thumb should cost no more to take back.
  Future<void> _dismiss(BuildContext context, SearchMiss miss) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await viewModel.dismiss(miss);
    switch (outcome) {
      case SearchMissActionOutcome.done:
        _announce(
          messenger,
          l10n.searchMissDismissedMessage(_isolated(miss.term)),
          action: SnackBarAction(
            label: l10n.undoButton,
            onPressed: () async {
              final undone = await viewModel.reopen(miss);
              if (undone == SearchMissActionOutcome.failed) {
                _announce(messenger, l10n.searchMissActionError);
              }
            },
          ),
        );
      case SearchMissActionOutcome.failed ||
          SearchMissActionOutcome.productRefused:
        _announce(messenger, l10n.searchMissActionError);
      case SearchMissActionOutcome.busy:
        break;
    }
  }

  Future<void> _reopen(BuildContext context, SearchMiss miss) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await viewModel.reopen(miss);
    _announce(messenger, switch (outcome) {
      SearchMissActionOutcome.done => l10n.searchMissReopenedMessage(
        _isolated(miss.term),
      ),
      SearchMissActionOutcome.failed ||
      SearchMissActionOutcome.productRefused => l10n.searchMissActionError,
      SearchMissActionOutcome.busy => null,
    });
  }

  void _announce(
    ScaffoldMessengerState messenger,
    String? message, {
    SnackBarAction? action,
  }) {
    if (message == null) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }
}

/// A typed word or a product name inside an Arabic sentence, isolated so a
/// Latin name or a leading number cannot reorder the words around it.
String _isolated(String text) => '\u{2068}$text\u{2069}';

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelected});

  final SearchMissFilter selected;
  final ValueChanged<SearchMissFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final filter in SearchMissFilter.values) ...[
            if (filter != SearchMissFilter.values.first)
              const SizedBox(width: 6),
            ChoiceChip(
              label: Text(switch (filter) {
                SearchMissFilter.open => l10n.searchMissesFilterOpen,
                SearchMissFilter.resolved => l10n.searchMissesFilterResolved,
                SearchMissFilter.dismissed => l10n.searchMissesFilterDismissed,
                SearchMissFilter.all => l10n.searchMissesFilterAll,
              }),
              selected: filter == selected,
              onSelected: (_) => onSelected(filter),
            ),
          ],
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.spacing});

  final AdaptiveSpacing spacing;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    // The list's header sits outside its padding, so the hint brings its own.
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.pageHorizontal,
        0,
        spacing.pageHorizontal,
        spacing.sm,
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: colors.mutedInk),
          SizedBox(width: spacing.xs),
          Expanded(
            child: Text(
              AppLocalizations.of(context)!.searchMissesHint,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ),
        ],
      ),
    );
  }
}
