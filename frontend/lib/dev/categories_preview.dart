// Dev-only preview harness for the categories route.
//
// Renders the redesigned category management screen (and the POS quick-access
// strip) full-viewport, with an in-memory fake repository and no backend/auth.
// Every action works — pin/unpin, drag-reorder, create, edit, delete — so the
// design can be exercised end to end. Pick the surface with a `?screen=` query
// param and resize the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/categories_preview.dart
//
// Screens: manage | empty | strip
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_category_query.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/category_management_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/category_management_screen.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
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
      home: const _Router(),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'manage';
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    switch (_screen()) {
      case 'empty':
        return _manage(seed: const []);
      case 'strip':
        return const _StripPreview();
      case 'manage':
      default:
        return _manage(seed: _seedCategories);
    }
  }
}

Widget _manage({required List<_Cat> seed}) {
  final repo = _FakeCatalogRepository(seed);
  return CategoryManagementScreen(
    viewModel: CategoryManagementViewModel(repo),
    navigation: _FakeNavigation(),
  );
}

// ---------------------------------------------------------------------------
// POS quick-access strip preview
// ---------------------------------------------------------------------------

class _StripPreview extends StatefulWidget {
  const _StripPreview();

  @override
  State<_StripPreview> createState() => _StripPreviewState();
}

class _StripPreviewState extends State<_StripPreview> {
  final CatalogRepository _repo = _FakeCatalogRepository(_seedCategories);
  List<ProductCategory> _selected = const [];

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Scaffold(
      backgroundColor: PointyColors.page,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Mock POS search bar.
                  Material(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(8),
                    child: const ListTile(
                      leading: Icon(Icons.search),
                      title: Text('ابحث عن منتج أو امسح الباركود'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  QuickAccessCategoryStrip(
                    catalogRepository: _repo,
                    selectedCategories: _selected,
                    allLabel: 'الكل',
                    onSelectAll: () => setState(() => _selected = const []),
                    onSelectCategory: (category) =>
                        setState(() => _selected = [category]),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surface,
                        border: Border.all(color: colors.line),
                        borderRadius: BorderRadius.circular(PointyRadii.card),
                      ),
                      child: Center(
                        child: Text(
                          _selected.isEmpty
                              ? 'كل المنتجات'
                              : 'منتجات: ${_selected.first.name}',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colors.mutedInk),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeNavigation implements AppNavigation {
  _FakeNavigation();

  @override
  final AuthorizationCapabilities capabilities =
      AuthorizationCapabilities.forUser(_managerUser);
  @override
  final PosUser currentUser = _managerUser;

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

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

/// In-memory category store backing the preview. Mutating methods update the
/// store so the harness behaves like the real thing.
class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(List<_Cat> seed) : super(PosApiService()) {
    _cats.addAll(seed.map((c) => c.clone()));
    _nextId = _cats.fold(0, (max, c) => c.id > max ? c.id : max) + 1;
  }

  final List<_Cat> _cats = [];
  int _nextId = 1;

  @override
  Future<Result<ProductCategoryPage>> loadProductCategories({
    ProductCategoryQuery query = const ProductCategoryQuery(),
    int page = 1,
  }) async {
    return Result.guard(() async {
      final search = query.search.trim();
      var matches = _cats.where((c) {
        if (query.rootOnly && c.parentId != null) return false;
        if (query.parentId != null && c.parentId != query.parentId) {
          return false;
        }
        if (query.quickAccessOnly && !c.isQuickAccess) return false;
        if (query.availability == ProductCategoryAvailabilityFilter.active &&
            !c.isActive) {
          return false;
        }
        if (search.isNotEmpty && !c.name.contains(search)) return false;
        return true;
      }).toList();
      matches.sort(_comparatorFor(query.ordering));
      return ProductCategoryPage(
        categories: matches.map(_toModel).toList(growable: false),
        hasMore: false,
      );
    });
  }

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async {
    return Result.guard(() async {
      final pinned = _cats.where((c) => c.isQuickAccess && c.isActive).toList()
        ..sort(_comparatorFor(ProductCategoryOrdering.manual));
      return pinned.map(_toModel).toList(growable: false);
    });
  }

  @override
  Future<Result<ProductCategory>> createProductCategory(
    ProductCategoryDraft draft,
  ) async {
    return Result.guard(() async {
      final cat = _Cat(
        id: _nextId++,
        name: draft.name,
        description: draft.description,
        parentId: draft.parentId,
        isActive: draft.isActive,
        isQuickAccess: draft.isQuickAccess,
        displayOrder: _cats.length,
        productCount: 0,
      );
      _cats.add(cat);
      return _toModel(cat);
    });
  }

  @override
  Future<Result<ProductCategory>> updateProductCategory({
    required int id,
    required ProductCategoryDraft draft,
  }) async {
    return Result.guard(() async {
      final cat = _cats.firstWhere((c) => c.id == id);
      cat
        ..name = draft.name
        ..description = draft.description
        ..parentId = draft.parentId
        ..isActive = draft.isActive
        ..isQuickAccess = draft.isQuickAccess;
      return _toModel(cat);
    });
  }

  @override
  Future<Result<ProductCategory>> setCategoryQuickAccess({
    required int id,
    required bool isQuickAccess,
  }) async {
    return Result.guard(() async {
      final cat = _cats.firstWhere((c) => c.id == id);
      cat.isQuickAccess = isQuickAccess;
      return _toModel(cat);
    });
  }

  @override
  Future<Result<void>> reorderQuickAccessCategories(
    List<int> orderedIds,
  ) async {
    return Result.guard(() async {
      for (var i = 0; i < orderedIds.length; i += 1) {
        _cats.firstWhere((c) => c.id == orderedIds[i]).displayOrder = i;
      }
    });
  }

  @override
  Future<Result<void>> deleteProductCategory(int id) async {
    return Result.guard(() async {
      _cats.removeWhere((c) => c.id == id);
    });
  }

  int Function(_Cat, _Cat) _comparatorFor(ProductCategoryOrdering ordering) {
    if (ordering == ProductCategoryOrdering.manual) {
      return (a, b) {
        final byOrder = a.displayOrder.compareTo(b.displayOrder);
        return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
      };
    }
    return (a, b) => a.name.compareTo(b.name);
  }

  String _nameForId(int? id) {
    if (id == null) return '';
    for (final c in _cats) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  ProductCategory _toModel(_Cat c) {
    return ProductCategory(
      id: c.id,
      name: c.name,
      description: c.description,
      parentId: c.parentId,
      parentName: _nameForId(c.parentId),
      childrenCount: _cats.where((x) => x.parentId == c.id).length,
      productCount: c.productCount,
      isActive: c.isActive,
      isQuickAccess: c.isQuickAccess,
      displayOrder: c.displayOrder,
    );
  }
}

class _Cat {
  _Cat({
    required this.id,
    required this.name,
    this.description = '',
    this.parentId,
    this.isActive = true,
    this.isQuickAccess = false,
    this.displayOrder = 0,
    this.productCount = 0,
  });

  final int id;
  String name;
  String description;
  int? parentId;
  bool isActive;
  bool isQuickAccess;
  int displayOrder;
  int productCount;

  _Cat clone() => _Cat(
    id: id,
    name: name,
    description: description,
    parentId: parentId,
    isActive: isActive,
    isQuickAccess: isQuickAccess,
    displayOrder: displayOrder,
    productCount: productCount,
  );
}

final List<_Cat> _seedCategories = [
  _Cat(id: 1, name: 'مشروبات', isQuickAccess: true, displayOrder: 0),
  _Cat(id: 2, name: 'ساخنة', parentId: 1, productCount: 4),
  _Cat(
    id: 3,
    name: 'قهوة',
    parentId: 2,
    productCount: 8,
    isQuickAccess: true,
    displayOrder: 2,
  ),
  _Cat(id: 4, name: 'شاي', parentId: 2, productCount: 5),
  _Cat(
    id: 5,
    name: 'باردة',
    parentId: 1,
    productCount: 6,
    isQuickAccess: true,
    displayOrder: 1,
  ),
  _Cat(id: 6, name: 'مأكولات', displayOrder: 1),
  _Cat(id: 7, name: 'حلويات', parentId: 6, productCount: 12),
  _Cat(id: 8, name: 'وجبات', parentId: 6, productCount: 9),
  _Cat(
    id: 9,
    name: 'إكسسوارات',
    displayOrder: 2,
    productCount: 3,
    isActive: false,
  ),
];
