// Dev-only preview harness for «عمليات بحث بلا نتائج», the owner's worklist of
// catalogue searches that found nothing.
//
// Renders the real screen against fake repositories: no server, no login, no
// shop data. Pick a surface with `?screen=`:
//
//   open      — the open words, most typed first (the default). «هذا المنتج…»
//               opens the real product picker over a small fake catalogue.
//   resolved  — words already linked to a product, each saying which.
//   all       — every word, whatever its status.
//   empty     — nothing recorded yet: the empty state says how the list fills.
//
// Add `&theme=dark` for the dark palette.
//
//   make frontend-search-misses-preview
//
// test/screens/search_misses_capture_test.dart renders the same surfaces to
// PNG. See AGENTS.md ("UI Preview Harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/search_miss.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/search_miss_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/search_misses_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/search_misses_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  final query = Uri.base.queryParameters;
  runApp(
    SearchMissesPreviewApp(
      screen: query['screen'] ?? 'open',
      theme: query['theme'] == 'dark'
          ? PointyTheme.dark()
          : PointyTheme.light(),
    ),
  );
}

class SearchMissesPreviewApp extends StatelessWidget {
  const SearchMissesPreviewApp({
    super.key,
    required this.screen,
    required this.theme,
    this.now,
  });

  final String screen;
  final ThemeData theme;

  /// Pinned by the PNG capture so «اليوم»/«أمس» never drift.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: theme,
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: _PreviewHome(screen: screen, now: now ?? DateTime.now()),
    );
  }
}

class _PreviewHome extends StatefulWidget {
  const _PreviewHome({required this.screen, required this.now});

  final String screen;
  final DateTime now;

  @override
  State<_PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<_PreviewHome> {
  late final SearchMissesViewModel _viewModel = SearchMissesViewModel(
    _PreviewSearchMissRepository(
      widget.screen == 'empty' ? const [] : _sampleRows(widget.now),
    ),
  );

  @override
  void initState() {
    super.initState();
    switch (widget.screen) {
      case 'resolved':
        _viewModel.setFilter(SearchMissFilter.resolved);
      case 'all':
        _viewModel.setFilter(SearchMissFilter.all);
    }
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SearchMissesScreen(
      viewModel: _viewModel,
      catalogRepository: _PreviewCatalogRepository(),
      navigation: _PreviewNavigation(),
      now: widget.now,
    );
  }
}

List<SearchMiss> _sampleRows(DateTime now) {
  DateTime ago({int days = 0, int hours = 0, int minutes = 0}) =>
      now.subtract(Duration(days: days, hours: hours, minutes: minutes));
  return [
    SearchMiss(
      id: 1,
      term: 'كاتشب575',
      count: 23,
      lastSeenAt: ago(minutes: 20),
      surface: SearchMissSurface.pos,
    ),
    SearchMiss(
      id: 2,
      term: 'حليب نيدو',
      count: 14,
      lastSeenAt: ago(hours: 2),
      surface: SearchMissSurface.pos,
    ),
    SearchMiss(
      id: 3,
      term: 'بيبسى دايت',
      count: 9,
      lastSeenAt: ago(days: 1, hours: 3),
      surface: SearchMissSurface.pos,
    ),
    SearchMiss(
      id: 4,
      term: 'زيت عافيه',
      count: 6,
      lastSeenAt: ago(days: 3),
      surface: SearchMissSurface.purchasing,
    ),
    SearchMiss(
      id: 5,
      term: 'شامبو هيد اند شولدرز',
      count: 2,
      lastSeenAt: ago(days: 5),
      surface: SearchMissSurface.catalog,
    ),
    SearchMiss(
      id: 6,
      term: 'ktchp',
      lastSeenAt: ago(days: 6),
      surface: SearchMissSurface.pos,
    ),
    SearchMiss(
      id: 7,
      term: 'ارز بسمتي',
      count: 18,
      lastSeenAt: ago(days: 2),
      surface: SearchMissSurface.pos,
      status: SearchMissStatus.resolved,
      productId: 11,
      productName: 'أرز بسمتي هندي 5 كغ',
    ),
    SearchMiss(
      id: 8,
      term: 'تن',
      count: 7,
      lastSeenAt: ago(days: 4),
      surface: SearchMissSurface.pos,
      status: SearchMissStatus.resolved,
      productId: 12,
      productName: 'تونة ريو ماري',
    ),
    SearchMiss(
      id: 9,
      term: 'زززز',
      count: 2,
      lastSeenAt: ago(days: 8),
      surface: SearchMissSurface.pos,
      status: SearchMissStatus.dismissed,
    ),
  ];
}

/// Filters and sorts like the server, on one page, and changes rows in place.
class _PreviewSearchMissRepository extends SearchMissRepository {
  _PreviewSearchMissRepository(List<SearchMiss> rows)
    : _rows = [...rows],
      super(PosApiService());

  final List<SearchMiss> _rows;

  @override
  Future<Result<SearchMissPage>> loadMisses({
    int page = 1,
    SearchMissFilter filter = SearchMissFilter.open,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final rows = _rows.where((row) => filter.includes(row.status)).toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return Ok(SearchMissPage(misses: rows, hasMore: false));
  }

  @override
  Future<Result<SearchMiss>> resolve(int id, {required int productId}) async {
    final product = _catalog.firstWhere(
      (variant) => variant.productId == productId,
    );
    return _change(
      id,
      SearchMissStatus.resolved,
      productId: productId,
      productName: product.productName,
    );
  }

  @override
  Future<Result<SearchMiss>> dismiss(int id) async =>
      _change(id, SearchMissStatus.dismissed);

  @override
  Future<Result<SearchMiss>> reopen(int id) async =>
      _change(id, SearchMissStatus.open);

  Result<SearchMiss> _change(
    int id,
    SearchMissStatus status, {
    int? productId,
    String? productName,
  }) {
    final index = _rows.indexWhere((row) => row.id == id);
    final row = _rows[index];
    final updated = SearchMiss(
      id: row.id,
      term: row.term,
      normalized: row.normalized,
      surface: row.surface,
      count: row.count,
      lastSeenAt: row.lastSeenAt,
      status: status,
      productId: productId,
      productName: productName,
    );
    _rows[index] = updated;
    return Ok(updated);
  }
}

const _catalog = [
  ProductVariant(
    id: 21,
    productId: 21,
    productName: 'كاتشب هاينز',
    name: '575 غ',
    sku: 'HNZ-575',
    unitPrice: 12.5,
  ),
  ProductVariant(
    id: 22,
    productId: 22,
    productName: 'حليب نيدو كامل الدسم',
    name: '900 غ',
    sku: 'NIDO-900',
    unitPrice: 48,
  ),
  ProductVariant(
    id: 23,
    productId: 23,
    productName: 'بيبسي دايت',
    name: 'علبة 330 مل',
    sku: 'PEP-D-330',
    unitPrice: 2.5,
  ),
];

class _PreviewCatalogRepository extends CatalogRepository {
  _PreviewCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    final search = query.search.trim();
    return Ok(
      ProductVariantPage(
        variants: [
          for (final variant in _catalog)
            if (search.isEmpty || variant.productName.contains(search)) variant,
        ],
        hasMore: false,
      ),
    );
  }
}

class _PreviewNavigation implements AppNavigation {
  @override
  final PosUser currentUser = PosUser.fromJson(const {
    'id': 1,
    'username': 'owner',
    'display_name': 'صاحب المتجر',
    'role': 'manager',
    'permissions': <String>[],
  });

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(currentUser);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}
