import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_preview.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_rule.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

BulkPriceSummary bulkSummary({
  int matched = 3,
  int changed = 2,
  int increased = 2,
  int decreased = 0,
  int warnings = 0,
  List<int> stepCounts = const [2],
}) => BulkPriceSummary(
  matched: matched,
  changed: changed,
  unchanged: matched - changed,
  increased: increased,
  decreased: decreased,
  productsChanged: changed,
  packsChanged: 0,
  averageChangePercent: 10,
  warnings: warnings,
  flagCounts: const {},
  stepCounts: stepCounts,
);

BulkPricePreview bulkPreview({
  String fingerprint = 'fp-1',
  BulkPriceSummary? summary,
  int count = 2,
  List<BulkPricePreviewRow>? rows,
}) => BulkPricePreview(
  fingerprint: fingerprint,
  summary: summary ?? bulkSummary(),
  costVisible: true,
  view: BulkPricePreviewView.changed,
  count: count,
  rows:
      rows ??
      const [
        BulkPricePreviewRow(
          variantId: 1,
          productId: 1,
          productName: 'كولا',
          variantName: '',
          sku: 'C-1',
          oldPrice: 2,
          newPrice: 2.2,
          deltaPercent: 10,
          appliedSteps: [0],
          flags: {},
          packs: [],
          cost: 1.5,
        ),
        BulkPricePreviewRow(
          variantId: 2,
          productId: 2,
          productName: 'مياه',
          variantName: '',
          sku: 'W-1',
          oldPrice: 1,
          newPrice: 1.1,
          deltaPercent: 10,
          appliedSteps: [0],
          flags: {BulkPriceFlag.belowCost},
          packs: [],
        ),
      ],
);

/// Records what the editor asked for and answers from queues.
class FakeBulkPriceRepository extends CatalogRepository {
  FakeBulkPriceRepository() : super(PosApiService());

  final previewCalls =
      <({Map<String, Object?> spec, BulkPricePreviewView view, int offset})>[];
  final applyCalls = <({Map<String, Object?> spec, String fingerprint})>[];
  final revertCalls = <int>[];
  final previews = <Result<BulkPricePreview>>[];
  Result<BulkPricePreview> fallbackPreview = Ok(bulkPreview());
  Result<BulkPriceChangeRecord>? applyResult;
  Result<List<BulkPriceChangeRecord>> history = const Ok([]);
  Result<BulkPriceChangeRecord>? revertResult;
  bool costVisible = true;

  @override
  Future<Result<BulkPriceOptions>> loadBulkPriceOptions() async =>
      Ok(BulkPriceOptions(costVisible: costVisible, maxSteps: 20));

  @override
  Future<Result<BulkPricePreview>> previewBulkPriceChange({
    required BulkPriceSpec spec,
    BulkPricePreviewView view = BulkPricePreviewView.changed,
    int offset = 0,
    int limit = 50,
  }) async {
    previewCalls.add((spec: spec.toJson(), view: view, offset: offset));
    return previews.isEmpty ? fallbackPreview : previews.removeAt(0);
  }

  @override
  Future<Result<BulkPriceChangeRecord>> applyBulkPriceChange({
    required BulkPriceSpec spec,
    required String fingerprint,
  }) async {
    applyCalls.add((spec: spec.toJson(), fingerprint: fingerprint));
    return applyResult ?? Ok(bulkRecord());
  }

  @override
  Future<Result<List<BulkPriceChangeRecord>>> loadBulkPriceChanges() async =>
      history;

  @override
  Future<Result<BulkPriceChangeRecord>> revertBulkPriceChange(int id) async {
    revertCalls.add(id);
    return revertResult ??
        Ok(
          bulkRecord(
            id: id,
            revertedAt: DateTime(2026, 10, 19),
            revert: const BulkPriceRevertSummary(restored: 2, skipped: 1),
          ),
        );
  }
}

BulkPriceChangeRecord bulkRecord({
  int id = 7,
  int changed = 2,
  DateTime? revertedAt,
  BulkPriceRevertSummary? revert,
}) => BulkPriceChangeRecord(
  id: id,
  createdAt: DateTime(2026, 10, 18, 9, 30),
  createdByName: 'المالك',
  changed: changed,
  increased: changed,
  decreased: 0,
  stepCount: 1,
  revertedAt: revertedAt,
  revert: revert,
);

Widget bulkPriceApp(Widget home) => MaterialApp(
  locale: const Locale('ar'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: PointyTheme.light(),
  home: home,
);

Future<void> setSurface(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
