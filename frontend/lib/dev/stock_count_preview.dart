// Dev-only preview harness for the stock-count feature.
//
// Renders one stock-count surface at a time, full-viewport, with fake
// repositories and no backend/auth. Pick the surface with a `?screen=` query
// param and resize the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/stock_count_preview.dart
//
// Screens: board | sessions | counting-empty | counting-item | recon
//          | recon-empty | variance | reentry | search | start-form
//
// `?screen=board` is the "design board": every screen/state laid out at once in
// fixed device frames, for a single overview screenshot (size the viewport large
// — e.g. 1500x4000 — so Flutter paints the whole board). The other values render
// one surface full-viewport for per-screen, real-viewport responsive QA.
//
// See AGENTS.md ("UI preview harness") for the full pattern and how to clone it
// for another route. Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_category_query.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/models/stock_count_draft.dart';
import 'package:pointy_frontend/src/data/models/stock_count_line.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/stock_count_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/stock_count/view_models/stock_count_sessions_view_model.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_add_replace_sheet.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_counting_screen.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_item_search_sheet.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_reconciliation_screen.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_sessions_screen.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_variance_prompt.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

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
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _PreviewRouter(),
    );
  }
}

String _selectedScreen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'sessions';
}

class _PreviewRouter extends StatelessWidget {
  const _PreviewRouter();

  @override
  Widget build(BuildContext context) {
    switch (_selectedScreen()) {
      case 'board':
        return const _DesignBoard();
      case 'counting-empty':
        return _countingScreen();
      case 'counting-item':
        return _countingItem();
      case 'recon':
        return _reconciliation(_varianceLines);
      case 'recon-empty':
        return _reconciliation(const []);
      case 'variance':
        return _SheetHost(
          open: (context) => showStockCountVariancePrompt(
            context,
            expected: '24',
            counted: '19',
          ),
        );
      case 'reentry':
        return _SheetHost(
          open: (context) =>
              showStockCountReentrySheet(context, existing: '12'),
        );
      case 'search':
        return _SheetHost(
          open: (context) => showStockCountItemSearchSheet(
            context,
            catalogRepository: _FakeCatalogRepository(_variants),
          ),
        );
      case 'start-form':
        return _SheetHost(
          open: (context) => showStockCountStartForm(
            context,
            _FakeCatalogRepository(_variants),
          ),
        );
      case 'sessions':
      default:
        return _sessions();
    }
  }
}

Widget _sessions() {
  final repo = _FakeStockCountRepository(
    current: _currentSession,
    history: _history,
  );
  return StockCountSessionsScreen(
    viewModel: StockCountSessionsViewModel(repo),
    stockCountRepository: repo,
    catalogRepository: _FakeCatalogRepository(_variants),
    capabilities: _managerCaps,
    navigation: _FakeNavigation(_managerCaps, _managerUser),
  );
}

Widget _countingScreen() {
  final repo = _FakeStockCountRepository(current: _currentSession);
  return StockCountCountingScreen(
    session: _currentSession,
    stockCountRepository: repo,
    catalogRepository: _FakeCatalogRepository(_variants),
    capabilities: _managerCaps,
  );
}

Widget _countingItem() {
  return PointyScaffold(
    appBar: const PointyAppBar(
      title: Text('الجرد'),
      style: PointyAppBarStyle.highFocus,
      actions: [
        IconButton(onPressed: null, icon: Icon(Icons.search), tooltip: 'بحث'),
        IconButton(
          onPressed: null,
          icon: Icon(Icons.document_scanner_outlined),
          tooltip: 'كاميرا',
        ),
      ],
    ),
    body: StockCountCountingBody(
      session: _currentSession,
      counted: 21,
      total: 48,
      progress: 21 / 48,
      variant: _variants[0],
      input: '18',
      onSearch: () {},
      onCamera: () {},
      onDigit: (_) {},
      onDecimal: () {},
      onBackspace: () {},
      onClear: () {},
      footer: PointyStickyActionFooter(
        primaryAction: FilledButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.check),
          label: const Text('حفظ والتالي'),
        ),
        secondaryActions: [
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('إنهاء ومراجعة'),
          ),
        ],
      ),
    ),
  );
}

Widget _reconciliation(List<StockCountLine> lines) {
  final repo = _FakeStockCountRepository(
    current: _currentSession,
    lines: lines,
  );
  return StockCountReconciliationScreen(
    session: _currentSession,
    stockCountRepository: repo,
    capabilities: _managerCaps,
  );
}

/// Hosts a sheet/dialog over a neutral page and opens it once on first frame.
class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.open});

  final Future<void> Function(BuildContext context) open;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.open(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PointyColors.page,
      appBar: PointyAppBar(title: const Text('معاينة')),
      body: const Center(
        child: Text(
          'Sheet preview',
          style: TextStyle(color: Color(0xFF98A2B3)),
        ),
      ),
    );
  }
}

/// The "design board": every screen/state at once in fixed device frames.
///
/// Each frame pins its own logical size with a [MediaQuery] override so a single
/// `_PreviewApp` window shows phone and wide layouts side by side. Capture it
/// with one screenshot after sizing the browser large enough to paint it all
/// (Flutter only paints what is inside the viewport).
class _DesignBoard extends StatelessWidget {
  const _DesignBoard();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9E7E1),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 28,
          runSpacing: 28,
          children: [
            _Frame(label: 'Sessions', width: 390, child: _sessions()),
            _Frame(label: 'Sessions', width: 1000, child: _sessions()),
            _Frame(
              label: 'Counting (empty)',
              width: 390,
              child: _countingScreen(),
            ),
            _Frame(
              label: 'Counting (item)',
              width: 390,
              child: _countingItem(),
            ),
            _Frame(
              label: 'Counting (item)',
              width: 1180,
              child: _countingItem(),
            ),
            _Frame(
              label: 'Reconciliation',
              width: 390,
              child: _reconciliation(_varianceLines),
            ),
            _Frame(
              label: 'Reconciliation',
              width: 1180,
              child: _reconciliation(_varianceLines),
            ),
            _Frame(
              label: 'Reconciliation (matched)',
              width: 390,
              child: _reconciliation(const []),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labelled device frame that renders [child] as if the viewport were
/// [width] x [_frameHeight]. Keep frame widths below 1024 for screens that show
/// a navigation rail (e.g. Sessions) unless you want to preview the rail too.
class _Frame extends StatelessWidget {
  const _Frame({required this.label, required this.width, required this.child});

  static const double _frameHeight = 780;

  final String label;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label · ${width.toInt()}px',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF101828),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: width,
          height: _frameHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF101828), width: 2),
          ),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: Size(width, _frameHeight),
              padding: EdgeInsets.zero,
              viewPadding: EdgeInsets.zero,
              viewInsets: EdgeInsets.zero,
            ),
            child: child,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

class _FakeNavigation implements AppNavigation {
  _FakeNavigation(this.capabilities, this.currentUser);

  @override
  final AuthorizationCapabilities capabilities;
  @override
  final PosUser currentUser;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

class _FakeStockCountRepository extends StockCountRepository {
  _FakeStockCountRepository({
    this.current,
    this.history = const [],
    this.lines = const [],
  }) : super(PosApiService());

  final StockCount? current;
  final List<StockCount> history;
  final List<StockCountLine> lines;

  @override
  Future<Result<StockCount?>> loadCurrentCount() async => Ok(current);

  @override
  Future<Result<StockCountPage>> loadCounts({
    String? status,
    int page = 1,
  }) async {
    return Ok(
      StockCountPage(counts: page == 1 ? history : const [], hasMore: false),
    );
  }

  @override
  Future<Result<List<StockCountLine>>> loadReconciliation(int countId) async {
    return Ok(lines);
  }

  @override
  Future<Result<StockCount>> applyCount(
    int countId, {
    required String idempotencyKey,
  }) async {
    return Ok(current!);
  }

  @override
  Future<Result<StockCount>> startCount(StockCountStartDraft draft) async {
    return Ok(current!);
  }

  @override
  Future<Result<StockCountLine>> recordLine(
    int countId,
    StockCountLineDraft draft,
  ) async {
    return Ok(
      StockCountLine(
        id: 1,
        stockCountId: countId,
        variantId: draft.variantId,
        countedQuantity: draft.countedQuantity,
        expectedQuantity: draft.countedQuantity,
        variance: 0,
        needsReview: false,
        applied: false,
        staleAtApply: false,
      ),
    );
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this.variants) : super(PosApiService());

  final List<ProductVariant> variants;

  @override
  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    return Ok(variants.isNotEmpty ? variants.first : null);
  }

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    return Ok(ProductVariantPage(variants: variants, hasMore: false));
  }

  @override
  Future<Result<ProductCategoryPage>> loadProductCategories({
    ProductCategoryQuery query = const ProductCategoryQuery(),
    int page = 1,
  }) async {
    return const Ok(
      ProductCategoryPage(
        categories: [
          ProductCategory(id: 1, name: 'مشروبات'),
          ProductCategory(id: 2, name: 'وجبات خفيفة'),
          ProductCategory(id: 3, name: 'بقالة'),
        ],
        hasMore: false,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fake data
// ---------------------------------------------------------------------------

ProductVariant _variant(int id, String name, String sku) {
  return ProductVariant(
    id: id,
    productId: id,
    sku: sku,
    unitPrice: 10,
    productName: name,
    displayName: name,
  );
}

final List<ProductVariant> _variants = [
  _variant(1, 'عصير برتقال طبيعي 1 لتر', 'JUI-ORG-1L'),
  _variant(2, 'مياه معدنية 600 مل', 'WTR-600'),
  _variant(3, 'شيبس بطاطس بالملح', 'CHP-SLT'),
  _variant(4, 'قهوة عربية محمصة 250 جم', 'COF-AR-250'),
  _variant(5, 'بسكويت شوكولاتة', 'BSC-CHC'),
];

final StockCount _currentSession = StockCount(
  id: 104,
  countNumber: 'SC-104',
  status: StockCountStatus.inProgress,
  scope: StockCountScope.full,
  expectedLineCount: 48,
  countedLineCount: 21,
  varianceLineCount: 3,
  note: 'جرد نهاية الشهر',
  ownerName: 'سارة',
  createdAt: DateTime(2026, 6, 15, 9, 30),
);

final List<StockCount> _history = [
  StockCount(
    id: 103,
    countNumber: 'SC-103',
    status: StockCountStatus.applied,
    scope: StockCountScope.category,
    categoryName: 'مشروبات',
    expectedLineCount: 12,
    countedLineCount: 12,
    varianceLineCount: 5,
    appliedByName: 'محمد',
    createdAt: DateTime(2026, 6, 8, 18, 0),
  ),
  StockCount(
    id: 102,
    countNumber: 'SC-102',
    status: StockCountStatus.cancelled,
    scope: StockCountScope.full,
    expectedLineCount: 40,
    countedLineCount: 8,
    varianceLineCount: 0,
    createdAt: DateTime(2026, 6, 1, 12, 0),
  ),
  StockCount(
    id: 101,
    countNumber: 'SC-101',
    status: StockCountStatus.applied,
    scope: StockCountScope.full,
    expectedLineCount: 45,
    countedLineCount: 45,
    varianceLineCount: 0,
    appliedByName: 'سارة',
    createdAt: DateTime(2026, 5, 24, 20, 30),
  ),
];

StockCountLine _line(
  int id,
  ProductVariant variant,
  double expected,
  double counted,
) {
  return StockCountLine(
    id: id,
    stockCountId: 104,
    variantId: variant.id,
    countedQuantity: counted,
    expectedQuantity: expected,
    variance: counted - expected,
    needsReview: true,
    applied: false,
    staleAtApply: false,
    variant: variant,
  );
}

final List<StockCountLine> _varianceLines = [
  _line(1, _variants[0], 24, 19),
  _line(2, _variants[1], 60, 72),
  _line(3, _variants[2], 15, 12),
  _line(4, _variants[3], 8, 8.5),
];
