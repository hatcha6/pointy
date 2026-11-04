// Dev-only preview harness for the bulk expiry-tracking page and the expiry
// reminder section on a variant's details.
//
// Fake catalog repository, no backend, no auth.
//
//   make frontend-bulk-tracking-preview
//
// Screens: tracking (default) | previewed | filtered | selection | reminder |
// board. `previewed` has already run the preview, so both warnings, refused
// rows and the apply button are on screen.
//
// `?screen=board` lays a phone frame and a wide frame side by side (size the
// viewport large, e.g. 1900x1000). See AGENTS.md ("UI preview harness").
// Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_rule.dart';
import 'package:pointy_frontend/src/data/models/bulk_tracking_change.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/bulk_tracking_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/bulk_tracking/bulk_tracking_screen.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_expiry_reminder_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
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
      darkTheme: PointyTheme.dark(),
      themeMode: Uri.base.queryParameters['dark'] == '1'
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _PreviewRouter(),
    );
  }
}

class _PreviewRouter extends StatelessWidget {
  const _PreviewRouter();

  @override
  Widget build(BuildContext context) {
    final screen = Uri.base.queryParameters['screen'] ?? 'tracking';
    return switch (screen) {
      'board' => const _Board(),
      'reminder' => const _ReminderHost(),
      _ => _screenFor(screen),
    };
  }
}

Widget _screenFor(String screen) {
  final repository = _FakeCatalogRepository();
  final viewModel = BulkTrackingViewModel(
    catalogRepository: repository,
    batchSize: 4,
    selectedProducts: screen == 'selection'
        ? const [
            BulkPriceRef(id: 1, label: 'حليب المراعي 1 لتر'),
            BulkPriceRef(id: 2, label: 'زبادي دانون'),
            BulkPriceRef(id: 6, label: 'مسكن بنادول'),
          ]
        : const [],
  );
  if (screen == 'filtered') {
    viewModel.setScopeAll(false);
    viewModel.updateCondition(
      viewModel.filter.children.first.key,
      (c) => c.copyWith(
        refs: const [
          BulkPriceRef(id: 10, label: 'ألبان'),
          BulkPriceRef(id: 11, label: 'أدوية'),
        ],
      ),
    );
  }
  if (screen == 'previewed' || screen == 'filtered') {
    viewModel.setTracking(BulkTrackingTarget.expiry);
    viewModel.refreshPreview();
  }
  return BulkTrackingScreen(
    catalogRepository: repository,
    viewModel: viewModel,
  );
}

class _ReminderHost extends StatelessWidget {
  const _ReminderHost();

  @override
  Widget build(BuildContext context) {
    final capabilities = AuthorizationCapabilities.forUser(
      PosUser.fromJson(const {
        'id': 1,
        'username': 'manager',
        'display_name': 'مدير النظام',
        'email': '',
        'role': 'manager',
        'permissions': <String>[],
        'is_active': true,
      }),
    );
    final repository = _FakeCatalogRepository();
    Product product(String name, DateTime? reminder) => Product(
      id: 1,
      name: name,
      quantityOnHand: 12,
      defaultVariant: ProductVariant(
        id: 7,
        productId: 1,
        sku: 'MLK-1',
        unitPrice: 4.5,
        expiryReminderDate: reminder,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.variantDetailsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ProductExpiryReminderSection(
            product: product('حليب المراعي 1 لتر', DateTime(2027, 3, 31)),
            capabilities: capabilities,
            catalogRepository: repository,
          ),
          ProductExpiryReminderSection(
            product: product('زبادي دانون', null),
            capabilities: capabilities,
            catalogRepository: repository,
          ),
        ],
      ),
    );
  }
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    Widget frame(double width, double height, String screen) => SizedBox(
      width: width,
      height: height,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, height),
          padding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        child: ClipRect(
          child: Navigator(
            onGenerateRoute: (_) =>
                MaterialPageRoute(builder: (_) => _screenFor(screen)),
          ),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: const Color(0xFF444444),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            frame(390, 1100, 'previewed'),
            frame(1100, 1100, 'previewed'),
          ],
        ),
      ),
    );
  }
}

BulkTrackingRow _row(
  int id,
  String name,
  BulkTrackingOutcome outcome, {
  double onHand = 12,
  int variants = 1,
  String mode = 'quantity',
  String message = '',
  Set<BulkTrackingWarning> warnings = const {},
}) => BulkTrackingRow(
  product: id,
  name: name,
  outcome: outcome,
  onHand: onHand,
  variants: variants,
  currentMode: mode,
  message: message,
  warnings: warnings,
);

final _rows = [
  _row(
    1,
    'حليب المراعي 1 لتر',
    BulkTrackingOutcome.change,
    onHand: 48,
    warnings: {BulkTrackingWarning.undatedStock},
  ),
  _row(
    2,
    'زبادي دانون',
    BulkTrackingOutcome.change,
    onHand: 30,
    warnings: {BulkTrackingWarning.undatedStock},
  ),
  _row(
    3,
    'جبنة كيري 8 قطع',
    BulkTrackingOutcome.change,
    onHand: 0,
    warnings: {BulkTrackingWarning.emptyShelf},
  ),
  _row(
    4,
    'عصير راني برتقال',
    BulkTrackingOutcome.change,
    onHand: 0,
    warnings: {BulkTrackingWarning.emptyShelf},
  ),
  _row(5, 'قشطة نادك', BulkTrackingOutcome.change, onHand: 9, variants: 2),
  _row(
    6,
    'مسكن بنادول',
    BulkTrackingOutcome.change,
    onHand: 120,
    warnings: {BulkTrackingWarning.undatedStock},
  ),
  _row(
    7,
    'هاتف سامسونغ A15',
    BulkTrackingOutcome.blocked,
    onHand: 5,
    mode: 'serial',
    message:
        'هذا المنتج يُتتبَّع بالرقم التسلسلي، ولا يمكن تحويله إلى تتبّع الصلاحية.',
  ),
  _row(
    8,
    'وجبة شاورما',
    BulkTrackingOutcome.blocked,
    message: 'منتج يُحضَّر عند الطلب ولا رصيد له.',
  ),
  _row(9, 'لبن رائب', BulkTrackingOutcome.same, mode: 'batch', onHand: 14),
  _row(10, 'مياه معدنية', BulkTrackingOutcome.same, mode: 'batch', onHand: 90),
];

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<BulkTrackingPreview>> previewBulkTrackingChange({
    required BulkTrackingAction action,
    required BulkPriceGroup filter,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    int count(BulkTrackingOutcome o) =>
        _rows.where((r) => r.outcome == o).length;
    return Ok(
      BulkTrackingPreview(
        summary: BulkTrackingSummary(
          matched: _rows.length,
          change: count(BulkTrackingOutcome.change),
          same: count(BulkTrackingOutcome.same),
          blocked: count(BulkTrackingOutcome.blocked),
          emptyShelf: _rows.where((r) => r.isEmptyShelf).length,
          undatedStock: _rows.where((r) => r.isUndatedStock).length,
        ),
        rows: _rows,
      ),
    );
  }

  @override
  Future<Result<BulkTrackingApplyResult>> applyBulkTrackingChange({
    required BulkTrackingAction action,
    required BulkPriceGroup filter,
    required List<int> productIds,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return Ok(BulkTrackingApplyResult(done: productIds.length));
  }

  @override
  Future<Result<ProductVariant>> setVariantExpiryReminder(
    int variantId,
    DateTime? date,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return Ok(
      ProductVariant(
        id: variantId,
        productId: 1,
        sku: 'MLK-1',
        unitPrice: 4.5,
        expiryReminderDate: date,
      ),
    );
  }
}
