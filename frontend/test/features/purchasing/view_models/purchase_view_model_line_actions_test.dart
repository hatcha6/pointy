import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

void main() {
  const coffee = ProductVariant(
    id: 11,
    productId: 5,
    sku: 'COF',
    unitPrice: 10,
  );
  const tea = ProductVariant(id: 12, productId: 6, sku: 'TEA', unitPrice: 4);

  PurchaseViewModel build({double? lastCost}) => PurchaseViewModel(
    _FakeCatalogRepository(),
    _FakePurchaseRepository(lastCost: lastCost),
  );

  group('deleting a line', () {
    test(
      'removeLine reports where the line sat so it can be put back',
      () async {
        final viewModel = build();
        await viewModel.addVariant(coffee);
        await viewModel.addVariant(tea);

        final removed = viewModel.removeLine(coffee.id);

        expect(removed, isNotNull);
        expect(removed!.index, 0);
        expect(viewModel.draft.map((line) => line.variant.id), [12]);
      },
    );

    test('restoreLine puts it back at the same position', () async {
      final viewModel = build();
      await viewModel.addVariant(coffee);
      await viewModel.addVariant(tea);
      final removed = viewModel.removeLine(coffee.id)!;

      viewModel.restoreLine(removed);

      expect(
        viewModel.draft.map((line) => line.variant.id),
        [11, 12],
        reason: 'an undone delete must not reorder the draft',
      );
    });

    test('restoring twice cannot duplicate the line', () async {
      final viewModel = build();
      await viewModel.addVariant(coffee);
      final removed = viewModel.removeLine(coffee.id)!;

      viewModel.restoreLine(removed);
      viewModel.restoreLine(removed);

      expect(viewModel.draft.length, 1);
    });

    test('removing the active line clears the keyboard target', () async {
      final viewModel = build();
      await viewModel.addVariant(coffee, source: 'purchase_catalog_tile');
      expect(viewModel.activeDraftLine?.variant.id, 11);

      viewModel.removeLine(coffee.id);

      expect(viewModel.activeDraftLine, isNull);
    });

    test('removing a line that is not there is a no-op', () async {
      final viewModel = build();
      await viewModel.addVariant(coffee);

      expect(viewModel.removeLine(999), isNull);
      expect(viewModel.draft.length, 1);
    });
  });

  group('the active line', () {
    test('a tapped line beats the last scanned one', () async {
      final viewModel = build();
      await viewModel.addVariant(coffee, source: 'purchase_barcode_lookup');
      await viewModel.addVariant(tea);

      viewModel.selectLine(tea.id);

      expect(viewModel.activeDraftLine?.variant.id, 12);
    });

    test(
      'falls back to the last scanned line when nothing is selected',
      () async {
        final viewModel = build();
        await viewModel.addVariant(coffee, source: 'purchase_barcode_lookup');

        expect(viewModel.activeDraftLine?.variant.id, 11);
      },
    );
  });

  group('entering a cost by line total', () {
    test('divides the total by the quantity', () async {
      final viewModel = build();
      await viewModel.addVariant(coffee, quantity: 4, unitCost: 10);

      viewModel.setLineCostFromTotal(coffee, 50);

      expect(viewModel.draft.single.unitCost, 12.5);
    });

    test('a negative total is refused', () async {
      final viewModel = build();
      await viewModel.addVariant(coffee, quantity: 4, unitCost: 10);

      viewModel.setLineCostFromTotal(coffee, -1);

      expect(viewModel.draft.single.unitCost, 10);
    });
  });

  group('the previous purchase cost', () {
    test('is remembered from the server read, not from what is typed', () async {
      final viewModel = build(lastCost: 8);
      await viewModel.addVariant(coffee);
      expect(viewModel.previousBaseCostFor(coffee.id), 8);

      // Typing a new cost must NOT move the anchor the line compares against —
      // otherwise "the cost went up" can never be true.
      viewModel.updateLineCost(coffee, 12);

      expect(viewModel.previousBaseCostFor(coffee.id), 8);
    });

    test('is absent for a product that has never been bought', () async {
      final viewModel = build(lastCost: null);
      await viewModel.addVariant(coffee);

      expect(viewModel.previousBaseCostFor(coffee.id), isNull);
    });
  });

  group('a typed quantity is reported in the direction it moved', () {
    // Every typed quantity used to be logged as a decrease: a week of field
    // data read 223 of 238 "decreases" that were buyers keying 24 over the
    // default 1.
    test('typing a larger quantity is an increase', () async {
      final engine = _RecordingEngine();
      final viewModel = PurchaseViewModel(
        _FakeCatalogRepository(),
        _FakePurchaseRepository(),
        analyticsEngine: engine,
      );
      await viewModel.addVariant(coffee);
      engine.tracked.clear();

      viewModel.setLineQuantity(coffee, 24);

      expect(
        engine.tracked.single.name,
        'purchasing.draft.line.quantity_increased',
      );
      expect(engine.tracked.single.severity, AnalyticsEventSeverity.info);
    });

    test('typing a smaller quantity is a decrease', () async {
      final engine = _RecordingEngine();
      final viewModel = PurchaseViewModel(
        _FakeCatalogRepository(),
        _FakePurchaseRepository(),
        analyticsEngine: engine,
      );
      await viewModel.addVariant(coffee, quantity: 24);
      engine.tracked.clear();

      viewModel.setLineQuantity(coffee, 6);

      expect(
        engine.tracked.single.name,
        'purchasing.draft.line.quantity_decreased',
      );
      expect(engine.tracked.single.severity, AnalyticsEventSeverity.warning);
    });
  });
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async => Ok(const AnalyticsIngestResult(accepted: 0, duplicates: 0));
}

class _RecordingEngine extends AnalyticsEngine {
  _RecordingEngine() : super(_NullSink());

  final List<AnalyticsEventDraft> tracked = [];

  @override
  Future<void> track(
    AnalyticsEventDraft event, {
    bool flushImmediately = false,
  }) async {
    tracked.add(event);
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository({this.lastCost}) : super(PosApiService());

  final double? lastCost;

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => Ok(lastCost);
}
