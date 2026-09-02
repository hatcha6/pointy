import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_suggestion.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_suggestion_controller.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

/// The suggestion strip's contract is mostly about restraint: it must not ask
/// the server more than it has to, must not blink, must not fight the buyer,
/// and must disappear entirely rather than show an empty state.
void main() {
  const coffee = ProductVariant(id: 11, productId: 5, sku: 'COF', unitPrice: 10);
  const tea = ProductVariant(id: 12, productId: 6, sku: 'TEA', unitPrice: 4);
  const supplier = SupplierContact(
    id: 3,
    name: 'مورد',
    contactName: '',
    phone: '',
    email: '',
    address: '',
    notes: '',
    isActive: true,
  );

  PurchaseSuggestion suggestion(
    int variantId, {
    double? quantity,
    double? baseUnitCost,
    String unit = '',
  }) {
    return PurchaseSuggestion(
      variantId: variantId,
      productId: variantId,
      productName: 'صنف $variantId',
      variantName: '',
      sku: 'SKU-$variantId',
      reason: PurchaseSuggestionReason.oftenWith,
      suggestedQuantity: quantity,
      unitCode: unit,
      baseUnitCost: baseUnitCost,
      unitCost: baseUnitCost,
    );
  }

  group('fetching', () {
    test('asks once per draft state and serves repeats from cache', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(items: [suggestion(12)]),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );

      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, 1);

      // Same state again — nothing to ask.
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, 1);

      // A line added, then removed: the second state is one we already know.
      controller.update(supplierId: 3, variantIds: const [11, 12]);
      await Future<void>.delayed(Duration.zero);
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);
      expect(
        repository.calls,
        2,
        reason: 'returning to a known draft state must not re-ask',
      );
    });

    test('a burst of edits collapses into one request', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(items: [suggestion(12)]),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: const Duration(milliseconds: 50),
        muteStorage: _MemoryStorage(),
      );

      controller.update(supplierId: 3, variantIds: const [11]);
      controller.update(supplierId: 3, variantIds: const [11, 12]);
      controller.update(supplierId: 3, variantIds: const [11, 12, 13]);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(repository.calls, 1);
    });

    test('keeps showing the previous answer while a new one is in flight', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(items: [suggestion(12)]),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: const Duration(milliseconds: 20),
        muteStorage: _MemoryStorage(),
      );
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controller.items, hasLength(1));

      controller.update(supplierId: 3, variantIds: const [11, 14]);

      expect(
        controller.items,
        hasLength(1),
        reason: 'a strip that blinks empty on every edit is worse than a stale one',
      );
    });

    test('a disabled shop is asked exactly once, ever', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet.disabled,
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );

      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);
      controller.update(supplierId: 3, variantIds: const [11, 12]);
      await Future<void>.delayed(Duration.zero);

      expect(repository.calls, 1);
      expect(controller.isVisible, isFalse);
    });

    test('a supplier with no history is asked once, not once per line', () async {
      final repository = _FakePurchaseRepository(
        set: const PurchaseSuggestionSet(),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );

      controller.update(supplierId: 3, variantIds: const []);
      await Future<void>.delayed(Duration.zero);
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);
      controller.update(supplierId: 3, variantIds: const [11, 12]);
      await Future<void>.delayed(Duration.zero);

      expect(repository.calls, 1);
    });

    test('a failed read shows nothing and does not throw', () async {
      final repository = _FakePurchaseRepository(fails: true);
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );

      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);

      expect(controller.hasAnything, isFalse);
    });

    test('no supplier means no request at all', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(items: [suggestion(12)]),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );

      controller.update(supplierId: null, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);

      expect(repository.calls, 0);
      expect(controller.isVisible, isFalse);
    });
  });

  group('what the strip shows', () {
    test('never offers something already on the draft', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(
          items: [suggestion(12), suggestion(13)],
        ),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);

      // The buyer adds one of the suggestions by hand before the next answer
      // lands — it must drop out of the strip immediately, not a request later.
      controller.update(supplierId: 3, variantIds: const [11, 12]);

      expect(controller.items.map((item) => item.variantId), [13]);
    });

    test('a muted product never comes back', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(items: [suggestion(12), suggestion(13)]),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);

      controller.mute(12);

      expect(controller.items.map((item) => item.variantId), [13]);
    });

    test('collapsing hides the strip for this draft only', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(items: [suggestion(12)]),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);

      controller.collapse();
      expect(controller.isVisible, isFalse);

      // A different supplier is a different order: dismissal was "not now".
      controller.update(supplierId: 4, variantIds: const []);
      expect(controller.isCollapsed, isFalse);
    });

    test('switching supplier drops the previous supplier\'s answers', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(items: [suggestion(12)]),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.items, hasLength(1));

      controller.update(supplierId: 4, variantIds: const [11]);

      expect(
        controller.items,
        isEmpty,
        reason: 'habits are per supplier — none of them carry over',
      );
    });

    test('the usual basket drops lines already on the draft', () async {
      final repository = _FakePurchaseRepository(
        set: PurchaseSuggestionSet(
          usualBasket: PurchaseUsualBasket(
            available: true,
            items: [suggestion(11), suggestion(12), suggestion(13)],
          ),
        ),
      );
      final controller = PurchaseSuggestionController(
        repository: repository,
        debounce: Duration.zero,
        muteStorage: _MemoryStorage(),
      );
      controller.update(supplierId: 3, variantIds: const [11]);
      await Future<void>.delayed(Duration.zero);

      expect(controller.usualBasket.lineCount, 2);
    });
  });

  group('accepting a suggestion', () {
    PurchaseViewModel build(PurchaseSuggestionSet set) {
      final repository = _FakePurchaseRepository(set: set);
      return PurchaseViewModel(
        _FakeCatalogRepository(const [coffee, tea]),
        repository,
        suggestionController: PurchaseSuggestionController(
          repository: repository,
          debounce: Duration.zero,
          muteStorage: _MemoryStorage(),
        ),
      );
    }

    test('adds the line at the suggested quantity', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          items: [suggestion(12, quantity: 6, baseUnitCost: 2.5)],
        ),
      );
      viewModel.selectSupplier(supplier);
      await Future<void>.delayed(Duration.zero);

      final accepted = await viewModel.acceptSuggestion(
        viewModel.suggestions.items.single,
      );

      expect(accepted, isTrue);
      expect(viewModel.draft.single.variant.id, 12);
      expect(viewModel.draft.single.quantity, 6);
      expect(viewModel.draft.single.unitCost, 2.5);
    });

    test('a suggestion with no quantity lands as one, like a catalog tap', () async {
      final viewModel = build(
        PurchaseSuggestionSet(items: [suggestion(12, baseUnitCost: 2.5)]),
      );
      viewModel.selectSupplier(supplier);
      await Future<void>.delayed(Duration.zero);

      await viewModel.acceptSuggestion(viewModel.suggestions.items.single);

      expect(viewModel.draft.single.quantity, 1);
    });

    test('seeds the previous-cost anchor so the line can say the cost moved', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          items: [suggestion(12, quantity: 3, baseUnitCost: 2.5)],
        ),
      );
      viewModel.selectSupplier(supplier);
      await Future<void>.delayed(Duration.zero);

      await viewModel.acceptSuggestion(viewModel.suggestions.items.single);

      expect(viewModel.previousBaseCostFor(12), 2.5);
    });

    test('filling the usual basket adds every missing line', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          usualBasket: PurchaseUsualBasket(
            available: true,
            items: [
              suggestion(11, quantity: 2, baseUnitCost: 5),
              suggestion(12, quantity: 6, baseUnitCost: 2.5),
            ],
          ),
        ),
      );
      viewModel.selectSupplier(supplier);
      await Future<void>.delayed(Duration.zero);

      final added = await viewModel.fillUsualBasket();

      expect(added, [11, 12]);
      expect(viewModel.draft.map((line) => line.quantity), [2, 6]);
    });

    test('filling twice cannot duplicate a line', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          usualBasket: PurchaseUsualBasket(
            available: true,
            items: [suggestion(11, quantity: 2, baseUnitCost: 5)],
          ),
        ),
      );
      viewModel.selectSupplier(supplier);
      await Future<void>.delayed(Duration.zero);

      await viewModel.fillUsualBasket();
      final second = await viewModel.fillUsualBasket();

      expect(second, isEmpty);
      expect(viewModel.draft, hasLength(1));
    });
  });

  group('the quantity hint', () {
    PurchaseViewModel build(PurchaseSuggestionSet set) {
      final repository = _FakePurchaseRepository(set: set);
      return PurchaseViewModel(
        _FakeCatalogRepository(const [coffee, tea]),
        repository,
        suggestionController: PurchaseSuggestionController(
          repository: repository,
          debounce: Duration.zero,
          muteStorage: _MemoryStorage(),
        ),
      );
    }

    test('offers the habitual quantity for a line sitting at one', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          usualBasket: PurchaseUsualBasket(
            available: true,
            items: [suggestion(11, quantity: 12, baseUnitCost: 5)],
          ),
        ),
      );
      viewModel.selectSupplier(supplier);
      await viewModel.addVariant(coffee);
      await Future<void>.delayed(Duration.zero);

      final hint = viewModel.quantityHintFor(viewModel.draft.single);

      expect(hint?.suggestedQuantity, 12);
    });

    test('goes quiet once the line is already at that quantity', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          usualBasket: PurchaseUsualBasket(
            available: true,
            items: [suggestion(11, quantity: 12, baseUnitCost: 5)],
          ),
        ),
      );
      viewModel.selectSupplier(supplier);
      await viewModel.addVariant(coffee, quantity: 12);
      await Future<void>.delayed(Duration.zero);

      expect(viewModel.quantityHintFor(viewModel.draft.single), isNull);
    });

    test('applying it sets the quantity', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          usualBasket: PurchaseUsualBasket(
            available: true,
            items: [suggestion(11, quantity: 12, baseUnitCost: 5)],
          ),
        ),
      );
      viewModel.selectSupplier(supplier);
      await viewModel.addVariant(coffee);
      await Future<void>.delayed(Duration.zero);
      final line = viewModel.draft.single;

      viewModel.applySuggestedQuantity(
        line,
        viewModel.quantityHintFor(line)!,
      );

      expect(viewModel.draft.single.quantity, 12);
    });

    test('a suggestion carrying no quantity produces no hint', () async {
      final viewModel = build(
        PurchaseSuggestionSet(
          usualBasket: PurchaseUsualBasket(
            available: true,
            items: [suggestion(11, baseUnitCost: 5)],
          ),
        ),
      );
      viewModel.selectSupplier(supplier);
      await viewModel.addVariant(coffee);
      await Future<void>.delayed(Duration.zero);

      expect(viewModel.quantityHintFor(viewModel.draft.single), isNull);
    });
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this.variants) : super(PosApiService());

  final List<ProductVariant> variants;

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => Ok(ProductVariantPage(variants: variants, hasMore: false));

  @override
  Future<List<ProductVariant>> loadVariantsByIds(Iterable<int> ids) async {
    final wanted = {...ids};
    return [
      for (final variant in variants)
        if (wanted.contains(variant.id)) variant,
    ];
  }

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository({
    this.set = const PurchaseSuggestionSet(),
    this.fails = false,
  }) : super(PosApiService());

  final PurchaseSuggestionSet set;
  final bool fails;
  int calls = 0;

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(null);

  @override
  Future<Result<PurchaseSuggestionSet>> loadPurchaseSuggestions({
    required int supplierId,
    List<int> variantIds = const [],
    int limit = 8,
  }) async {
    calls += 1;
    if (fails) {
      return Error(Exception('offline'));
    }
    return Ok(set);
  }
}

class _MemoryStorage implements ScopedJsonStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> load(String scope) async => _values[scope];

  @override
  Future<void> save(String scope, String json) async => _values[scope] = json;

  @override
  Future<void> clear(String scope) async => _values.remove(scope);
}
