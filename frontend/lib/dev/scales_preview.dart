// Dev-only preview harness for the weighing-scale surfaces.
// Safe to delete — never imported by lib/main.dart.
//
// Renders the scale-label rules screen and the scales (PLU push) screen with
// fake repositories — no backend, no scale on the LAN. The fakes are stateful,
// so adding a rule, editing one, assigning a PLU and pushing a scale all work
// and can be reviewed as real interactions rather than static mockups.
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/scales_preview.dart
//   (or `make frontend-scales-preview`)
//
// Screens: board | rules | rules-empty | scales | scales-empty | scales-wire
//
// Reload the browser once after the server reports "is being served at" so
// Flutter paints. See AGENTS.md ("UI Preview Harness").
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/scale.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/scales_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/scale_rules_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/scale_rules_screen.dart';
import 'package:pointy_frontend/src/features/scales/view_models/scales_view_model.dart';
import 'package:pointy_frontend/src/features/scales/views/scales_screen.dart';
import 'package:pointy_frontend/src/shared/barcode/scale_barcode.dart';
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
  return parsed?.queryParameters['screen'] ?? 'board';
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    switch (_screen()) {
      case 'rules':
        return _rules();
      case 'rules-empty':
        return _rules(empty: true);
      case 'scales':
        return _scales();
      case 'scales-empty':
        return _scales(empty: true);
      case 'scales-wire':
        return _scales(wireOnly: true);
      case 'board':
      default:
        return const _DesignBoard();
    }
  }
}

// ---------------------------------------------------------------------------
// Surfaces
// ---------------------------------------------------------------------------

Widget _rules({bool empty = false}) {
  return ScaleRulesScreen(
    viewModel: ScaleRulesViewModel(_FakeCatalogRepository(empty: empty)),
  );
}

Widget _scales({bool empty = false, bool wireOnly = false}) {
  return ScalesScreen(
    viewModel: ScalesViewModel(
      _FakeScalesRepository(empty: empty, wireOnly: wireOnly),
      _FakeCatalogRepository(),
    ),
  );
}

// ---------------------------------------------------------------------------
// Design board — every surface at once, in device frames
// ---------------------------------------------------------------------------

class _DesignBoard extends StatelessWidget {
  const _DesignBoard();

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Scaffold(
      backgroundColor: colors.page,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Wrap(
            spacing: 24,
            runSpacing: 24,
            children: [
              _frame('التنسيقات — ملء', _rules()),
              _frame('التنسيقات — فارغ', _rules(empty: true)),
              _frame('الموازين — ملء', _scales()),
              _frame('الموازين — فارغ', _scales(empty: true)),
              _frame('الموازين — عبر الشبكة', _scales(wireOnly: true)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _frame(String label, Widget child) {
    return Builder(
      builder: (context) {
        final colors = context.pointyColors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Container(
              width: 430,
              height: 900,
              decoration: BoxDecoration(
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: MediaQuery(
                data: const MediaQueryData(size: Size(430, 900)),
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

const _produceRule = ScaleBarcodeRule(
  id: 1,
  name: 'ميزان الخضار',
  pattern: '21IIIIIVVVVVC',
  valueDecimals: 3,
);
const _deliRule = ScaleBarcodeRule(
  id: 2,
  name: 'ميزان الديلي (سعر)',
  pattern: '23IIIIIVVVVVC',
  valueKind: ScaleValueKind.price,
  valueDecimals: 2,
);
const _legacyRule = ScaleBarcodeRule(
  id: 3,
  name: 'ميزان (وزن بالجرام)',
  pattern: '2XIIIIIVVVVVC',
  valueDecimals: 3,
  sequence: 100,
);

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository({this.empty = false})
    : _rules = empty
          ? <ScaleBarcodeRule>[]
          : <ScaleBarcodeRule>[_produceRule, _deliRule, _legacyRule],
      super(PosApiService());

  final bool empty;
  final List<ScaleBarcodeRule> _rules;
  int _nextId = 100;

  @override
  Future<List<ScaleBarcodeRule>> activeScaleRules({bool refresh = false}) async {
    return orderScaleRules(_rules);
  }

  @override
  Future<Result<List<ScaleBarcodeRule>>> loadScaleBarcodeRules({
    bool activeOnly = false,
  }) async {
    return Ok(List<ScaleBarcodeRule>.from(_rules));
  }

  @override
  Future<Result<ScaleBarcodeRule>> saveScaleBarcodeRule({
    int? id,
    required Map<String, Object?> draft,
  }) async {
    final saved = ScaleBarcodeRule.fromJson({
      ...draft,
      'id': id ?? _nextId++,
    }..putIfAbsent('name', () => 'تنسيق'));
    final index = _rules.indexWhere((rule) => rule.id == saved.id);
    if (index >= 0) {
      _rules[index] = saved;
    } else {
      _rules.add(saved);
    }
    return Ok(saved);
  }

  @override
  Future<Result<void>> deleteScaleBarcodeRule(int id) async {
    _rules.removeWhere((rule) => rule.id == id);
    return const Ok(null);
  }

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    final term = query.search.trim();
    final matches = [
      for (final variant in _catalog)
        if (term.isEmpty ||
            variant.displayName.contains(term) ||
            variant.sku.contains(term) ||
            variant.barcode.contains(term))
          variant,
    ];
    return Ok(ProductVariantPage(variants: matches, hasMore: false));
  }
}

const _catalog = <ProductVariant>[
  ProductVariant(
    id: 1,
    productId: 1,
    productName: 'طماطم',
    displayName: 'طماطم',
    fullName: 'طماطم',
    sku: 'TOM-001',
    unitPrice: 4.5,
    quantityOnHand: 80,
    barcode: '00001',
    unit: 'kg',
    isDefault: true,
  ),
  ProductVariant(
    id: 2,
    productId: 2,
    productName: 'جبن أبيض',
    displayName: 'جبن أبيض',
    fullName: 'جبن أبيض',
    sku: 'CHE-001',
    unitPrice: 40,
    quantityOnHand: 22,
    barcode: '00002',
    unit: 'kg',
    isDefault: true,
  ),
  ProductVariant(
    id: 3,
    productId: 3,
    productName: 'خبز عربي',
    displayName: 'خبز عربي',
    fullName: 'خبز عربي',
    sku: 'BRD-001',
    unitPrice: 1.5,
    quantityOnHand: 120,
    barcode: '00003',
    unit: 'piece',
    isDefault: true,
  ),
];

class _FakeScalesRepository extends ScalesRepository {
  _FakeScalesRepository({this.empty = false, this.wireOnly = false})
    : super(PosApiService());

  final bool empty;
  final bool wireOnly;
  int _pushes = 0;

  static const _fileScale = Scale(
    id: 1,
    name: 'ميزان الخضار',
    driver: 'file_export',
    driverLabel: 'ملف PLU (أي ميزان)',
    needsAddress: false,
  );
  static const _wireScale = Scale(
    id: 2,
    name: 'ميزان الديلي',
    driver: 'cas_cl5000',
    driverLabel: 'CAS CL5000 / CL7200',
    needsAddress: true,
    host: '192.168.1.50',
    port: 20304,
  );

  @override
  Future<Result<List<Scale>>> loadScales() async {
    if (empty) {
      return const Ok(<Scale>[]);
    }
    return Ok(wireOnly ? const [_wireScale] : const [_fileScale, _wireScale]);
  }

  @override
  Future<Result<List<ScaleDriverInfo>>> loadDrivers() async => const Ok([
    ScaleDriverInfo(
      key: 'file_export',
      label: 'ملف PLU (أي ميزان)',
      needsAddress: false,
      defaultPort: 0,
    ),
    ScaleDriverInfo(
      key: 'cas_cl5000',
      label: 'CAS CL5000 / CL7200',
      needsAddress: true,
      defaultPort: 20304,
    ),
    ScaleDriverInfo(
      key: 'aclas_ftp',
      label: 'Aclas LS2 (FTP)',
      needsAddress: true,
      defaultPort: 21,
    ),
  ]);

  @override
  Future<Result<List<ScalePlu>>> loadPlus() async {
    if (empty) {
      return const Ok(<ScalePlu>[]);
    }
    return const Ok([
      ScalePlu(
        id: 1,
        variantId: 1,
        pluNumber: 1,
        productName: 'طماطم',
        printedName: 'طماطم',
      ),
      ScalePlu(
        id: 2,
        variantId: 2,
        pluNumber: 2,
        productName: 'جبن أبيض',
        printedName: 'JEBEN ABYAD',
        labelName: 'JEBEN ABYAD',
        tareGrams: 8,
      ),
      ScalePlu(
        id: 3,
        variantId: 9,
        pluNumber: 3,
        productName: 'برتقال',
        printedName: 'برتقال',
        isActive: false,
      ),
    ]);
  }

  @override
  Future<Result<List<ScalePushJob>>> loadPushes(int id) async {
    if (empty) {
      return const Ok(<ScalePushJob>[]);
    }
    return Ok(
      id == 1
          ? const [
              ScalePushJob(
                id: 10,
                status: 'exported',
                pluCount: 2,
                sentCount: 2,
                filename: 'plu.csv',
              ),
            ]
          : const [
              ScalePushJob(
                id: 11,
                status: 'partial',
                pluCount: 3,
                sentCount: 2,
                failedCount: 1,
                errors: {'2': 'the scale refused it (error 82)'},
              ),
            ],
    );
  }

  @override
  Future<Result<ScalePushJob>> pushScale(int id) async {
    _pushes += 1;
    return Ok(
      id == 1
          ? ScalePushJob(
              id: 20 + _pushes,
              status: 'exported',
              pluCount: 2,
              sentCount: 2,
              filename: 'plu.csv',
            )
          : ScalePushJob(
              id: 20 + _pushes,
              status: 'succeeded',
              pluCount: 2,
              sentCount: 2,
            ),
    );
  }

  @override
  Future<Result<ScaleReachability>> checkScale(int id) async {
    return const Ok(ScaleReachability(reachable: true));
  }

  @override
  Future<Result<(String, Uint8List)>> exportPluFile(int id) async {
    final bytes = Uint8List.fromList(
      '1,طماطم,4.50,1,0\r\n2,JEBEN ABYAD,40.00,1,8\r\n'.codeUnits,
    );
    return Ok(('plu.csv', bytes));
  }

  @override
  Future<Result<Scale>> saveScale({
    int? id,
    required Map<String, Object?> draft,
  }) async {
    return Ok(Scale.fromJson({...draft, 'id': id ?? 99}));
  }

  @override
  Future<Result<void>> deleteScale(int id) async => const Ok(null);

  @override
  Future<Result<ScalePlu>> assignPlu({
    required int variantId,
    String labelName = '',
    int tareGrams = 0,
    int? shelfLifeDays,
  }) async {
    return Ok(
      ScalePlu(id: 90, variantId: variantId, pluNumber: 4, printedName: 'جديد'),
    );
  }

  @override
  Future<Result<ScalePlu>> updatePlu({
    required int id,
    required Map<String, Object?> changes,
  }) async {
    return Ok(ScalePlu(id: id, variantId: 1, pluNumber: 1));
  }
}
