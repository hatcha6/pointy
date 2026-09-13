import 'dart:math' as math;

import '../../core/result.dart';
import '../../core/server_state.dart';
import '../../core/token_lru_cache.dart';
import '../../shared/barcode/scale_barcode.dart';
import '../../shared/units.dart';
import '../models/attachment_summary.dart';
import '../models/barcode_resolution.dart';
import '../models/bought_together_product.dart';
import '../models/catalog_identity_conflict.dart';
import '../models/modifier_group.dart';
import '../models/product.dart';
import '../models/product_bulk_action.dart';
import '../models/unit_of_measure.dart';
import '../models/product_category.dart';
import '../models/product_category_query.dart';
import '../models/product_draft.dart';
import '../models/product_image_search_result.dart';
import '../models/product_image_upload.dart';
import '../models/product_page.dart';
import '../models/product_query.dart';
import '../models/product_unit.dart';
import '../models/product_update_draft.dart';
import '../models/product_variant.dart';
import '../models/product_variant_draft.dart';
import '../models/product_variant_page.dart';
import '../models/variant_option.dart';
import '../models/variant_option_draft.dart';
import '../models/variant_option_page.dart';
import '../models/variant_option_query.dart';
import '../models/variant_option_value.dart';
import '../models/variant_option_value_draft.dart';
import '../models/variant_option_value_page.dart';
import '../models/variant_option_value_query.dart';
import '../services/catalog_api_client.dart'
    show catalogProductIdBatchSize, catalogVariantIdBatchSize;
import '../services/pos_api_service.dart';

class CatalogRepository {
  CatalogRepository(this._service);

  final PosApiService _service;

  // Client-side caches for the POS hot paths, keyed on the backend's catalog
  // version token (pushed on every API response), so any product/price/stock
  // change server-side orphans them within one interaction. Money stays
  // correct regardless: checkout re-prices everything server-side — these
  // only ever affect what is displayed, bounded by the token + a short TTL.
  final TokenLruCache<BarcodeResolutionHit> _barcodeCache = TokenLruCache(
    capacity: 128,
    ttl: const Duration(minutes: 2),
  );
  final TokenLruCache<ProductPage> _productPageCache = TokenLruCache(
    capacity: 32,
    ttl: const Duration(seconds: 45),
  );

  // Scale rules describe a *layout*, not a price, and a shop changes one about
  // as often as it buys a scale. Keying them on the composite catalog token
  // would put a request on the scan path after every sale in the shop, so they
  // ride their own `scales` domain: it moves only when a rule is actually
  // edited, which makes another device's edit land immediately instead of
  // waiting out a ten-minute TTL. The TTL stays as the backstop for a backend
  // that publishes no versions at all.
  static const Duration _scaleRuleTtl = Duration(minutes: 10);
  static const String _singleton = 'singleton';
  final TokenLruCache<List<ScaleBarcodeRule>> _scaleRulesCache = TokenLruCache(
    capacity: 1,
    ttl: _scaleRuleTtl,
  );

  // The unit registry, cached the same way — on `catalog_defs`, because a unit
  // is a definition. It answers one question the till needs and the variant
  // payload deliberately does not carry: whether a product's base unit may be
  // sold in fractions. Putting it on every variant row would cost a query per
  // row in the catalog payload — the hottest response in the app — to repeat
  // one of about a dozen answers.
  final TokenLruCache<Map<String, UnitOfMeasure>> _unitRegistryCache =
      TokenLruCache(capacity: 1, ttl: _scaleRuleTtl);

  String? _domainToken(String domain) => _service.serverState.versionOf(domain);

  /// [bypassCache] is for a *revalidation*: the caller already knows the server
  /// says this data moved, so answering from the cache it is refreshing would
  /// defeat the point. Normally the token check below is enough — but the
  /// token and the reason for refreshing are two different counters, and a
  /// revalidation must not depend on them having moved together.
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async {
    final cacheKey = _productPageCacheKey(query, page);
    final cached = bypassCache
        ? null
        : _productPageCache.read(cacheKey, _service.catalogVersionToken);
    if (cached != null) {
      return Ok(cached);
    }
    final result = await Result.guard(
      () => _service.fetchProducts(query: query, page: page),
    );
    if (result is Ok<ProductPage>) {
      // Store under the token the response itself carried — the version this
      // payload is true for.
      _productPageCache.write(
        cacheKey,
        result.value,
        _service.catalogVersionToken,
      );
    }
    return result;
  }

  String _productPageCacheKey(ProductQuery query, int page) {
    final parameters = query.toQueryParameters(page: page);
    final keys = parameters.keys.toList()..sort();
    return keys.map((key) => '$key=${parameters[key]}').join('&');
  }

  Future<Result<Product>> createProduct(ProductDraft draft) async {
    return Result.guard(() => _service.createProduct(draft));
  }

  Future<Result<Product>> updateProduct({
    required int id,
    required ProductUpdateDraft draft,
  }) async {
    return Result.guard(() => _service.updateProduct(id: id, draft: draft));
  }

  Future<Result<Product>> loadProduct(int id) async {
    return Result.guard(() => _service.fetchProduct(id));
  }

  /// Loads a known set of products in as few requests as the server's page
  /// size allows (see [catalogProductIdBatchSize]). Ids the server does not
  /// know are simply absent from the result.
  Future<Result<List<Product>>> loadProductsByIds(List<int> ids) async {
    final distinct = ids.toSet().toList(growable: false);
    return Result.guard(() async {
      final products = <Product>[];
      for (
        var start = 0;
        start < distinct.length;
        start += catalogProductIdBatchSize
      ) {
        final end = math.min(
          start + catalogProductIdBatchSize,
          distinct.length,
        );
        products.addAll(
          await _service.fetchProductsByIds(distinct.sublist(start, end)),
        );
      }
      return products;
    });
  }

  Future<Result<List<BoughtTogetherProduct>>> loadBoughtTogether(
    int productId, {
    int limit = 8,
  }) async {
    return Result.guard(
      () => _service.fetchBoughtTogether(productId, limit: limit),
    );
  }

  Future<Result<Product>> archiveProduct(int id) async {
    return Result.guard(() => _service.archiveProduct(id));
  }

  Future<Result<Product>> restoreProduct(int id) async {
    return Result.guard(() => _service.restoreProduct(id));
  }

  Future<Result<int>> bulkArchiveProducts({
    required List<int> ids,
    required bool archived,
  }) async {
    return Result.guard(
      () => _service.bulkArchiveProducts(ids: ids, archived: archived),
    );
  }

  Future<Result<int>> bulkRepriceProducts({
    required List<int> ids,
    required ProductBulkRepriceMode mode,
    required double value,
  }) async {
    return Result.guard(
      () => _service.bulkRepriceProducts(
        ids: ids,
        mode: mode.apiValue,
        value: value,
      ),
    );
  }

  Future<Result<Product>> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
    Map<String, double?> pricesByUnitCode = const {},
  }) async {
    return Result.guard(
      () => _service.setVariantPrices(
        productId: productId,
        pricesByVariant: pricesByVariant,
        pricesByUnitCode: pricesByUnitCode,
      ),
    );
  }

  Future<Result<int>> bulkCategorizeProducts({
    required List<int> ids,
    required List<int> categoryIds,
    required ProductBulkCategorizeMode mode,
  }) async {
    return Result.guard(
      () => _service.bulkCategorizeProducts(
        ids: ids,
        categoryIds: categoryIds,
        mode: mode.apiValue,
      ),
    );
  }

  Future<Result<int>> bulkSetProductFlags({
    required List<int> ids,
    bool? isActive,
    bool? tracksExpiry,
    bool? isService,
    bool? isPrepared,
  }) async {
    return Result.guard(
      () => _service.bulkSetProductFlags(
        ids: ids,
        isActive: isActive,
        tracksExpiry: tracksExpiry,
        isService: isService,
        isPrepared: isPrepared,
      ),
    );
  }

  Future<Result<AttachmentSummary>> uploadProductImage({
    required int productId,
    required ProductImageUpload upload,
  }) async {
    return Result.guard(
      () => _service.uploadProductImage(productId: productId, upload: upload),
    );
  }

  Future<Result<AttachmentSummary>> importProductImage({
    required int productId,
    required String importToken,
  }) async {
    return Result.guard(
      () => _service.importProductImage(
        productId: productId,
        importToken: importToken,
      ),
    );
  }

  Future<Result<List<ProductImageSearchResult>>> searchProductImages({
    required String query,
    int page = 1,
    int? pageSize,
  }) async {
    return Result.guard(
      () => _service.searchProductImages(
        query: query,
        page: page,
        pageSize: pageSize,
      ),
    );
  }

  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchProductVariants(query: query, page: page),
    );
  }

  /// Loads an exact set of variants by id, in as few requests as the server's
  /// page size allows (one for a normal cart). Ids beyond the page size are
  /// split into further batches, and a failed batch drops out rather than
  /// failing the whole set — callers use this to refresh what they can.
  Future<List<ProductVariant>> loadVariantsByIds(Iterable<int> ids) async {
    final unique = <int>{...ids}.toList(growable: false);
    if (unique.isEmpty) {
      return const [];
    }
    final batches = <List<int>>[
      for (
        var start = 0;
        start < unique.length;
        start += catalogVariantIdBatchSize
      )
        unique.sublist(
          start,
          (start + catalogVariantIdBatchSize).clamp(0, unique.length),
        ),
    ];
    final pages = await Future.wait(
      batches.map(
        (batch) => Result.guard(() => _service.fetchVariantsByIds(batch)),
      ),
    );
    return [
      for (final page in pages)
        if (page case Ok<ProductVariantPage>(:final value)) ...value.variants,
    ];
  }

  Future<Result<ProductVariantPage>> loadVariantsForProduct(
    int productId, {
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchVariantsForProduct(productId, page: page),
    );
  }

  Future<Result<ProductVariant>> createProductVariant(
    ProductVariantDraft draft,
  ) async {
    return Result.guard(() => _service.createProductVariant(draft));
  }

  Future<Result<ProductVariant>> createVariantForProduct(
    int productId,
    ProductVariantDraft draft,
  ) async {
    return Result.guard(
      () => _service.createVariantForProduct(productId, draft),
    );
  }

  Future<Result<ProductVariant>> updateProductVariant({
    required int id,
    required ProductVariantDraft draft,
  }) async {
    return Result.guard(
      () => _service.updateProductVariant(id: id, draft: draft),
    );
  }

  Future<Result<void>> deleteProductVariant(int id) async {
    return Result.guard(() => _service.deleteProductVariant(id));
  }

  Future<Result<ProductCategoryPage>> loadProductCategories({
    ProductCategoryQuery query = const ProductCategoryQuery(),
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchProductCategories(query: query, page: page),
    );
  }

  Future<Result<ProductCategory>> createProductCategory(
    ProductCategoryDraft draft,
  ) async {
    return Result.guard(() => _service.createProductCategory(draft));
  }

  Future<Result<ProductCategory>> updateProductCategory({
    required int id,
    required ProductCategoryDraft draft,
  }) async {
    return Result.guard(
      () => _service.updateProductCategory(id: id, changes: draft.toJson()),
    );
  }

  /// Pin/unpin a category from the quick-access filter strip without touching
  /// its other fields.
  Future<Result<ProductCategory>> setCategoryQuickAccess({
    required int id,
    required bool isQuickAccess,
  }) async {
    return Result.guard(
      () => _service.updateProductCategory(
        id: id,
        changes: {'is_quick_access': isQuickAccess},
      ),
    );
  }

  /// Persist the order of the quick-access strip. [orderedIds] is the desired
  /// order; each category's `display_order` is set to its index.
  Future<Result<void>> reorderQuickAccessCategories(
    List<int> orderedIds,
  ) async {
    return Result.guard(() async {
      for (var index = 0; index < orderedIds.length; index += 1) {
        await _service.updateProductCategory(
          id: orderedIds[index],
          changes: {'display_order': index},
        );
      }
    });
  }

  Future<Result<void>> deleteProductCategory(int id) async {
    return Result.guard(() => _service.deleteProductCategory(id));
  }

  /// All active quick-access categories, ordered for the POS/purchasing strip.
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async {
    return Result.guard(() async {
      final categories = <ProductCategory>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchProductCategories(
          query: const ProductCategoryQuery(
            availability: ProductCategoryAvailabilityFilter.active,
            ordering: ProductCategoryOrdering.manual,
            quickAccessOnly: true,
          ),
          page: page,
        );
        categories.addAll(result.categories);
        hasMore = result.hasMore;
        page += 1;
      }
      return categories;
    });
  }

  Future<Result<VariantOptionValuePage>> loadVariantOptionValues({
    VariantOptionValueQuery query = const VariantOptionValueQuery(),
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchVariantOptionValues(query: query, page: page),
    );
  }

  Future<Result<VariantOptionValue>> createVariantOptionValue(
    VariantOptionValueDraft draft,
  ) async {
    return Result.guard(() => _service.createVariantOptionValue(draft));
  }

  Future<Result<VariantOptionPage>> loadVariantOptions({
    VariantOptionQuery query = const VariantOptionQuery(),
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchVariantOptions(query: query, page: page),
    );
  }

  Future<Result<VariantOption>> createVariantOption(
    VariantOptionDraft draft,
  ) async {
    return Result.guard(() => _service.createVariantOption(draft));
  }

  Future<Result<List<VariantOption>>> loadAllActiveVariantOptions() async {
    return Result.guard(() async {
      final options = <VariantOption>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchVariantOptions(
          query: const VariantOptionQuery(
            availability: VariantOptionAvailabilityFilter.active,
          ),
          page: page,
        );
        options.addAll(result.options);
        hasMore = result.hasMore;
        page += 1;
      }
      return options;
    });
  }

  Future<Result<List<ModifierGroup>>> loadAllModifierGroups() async {
    return Result.guard(() async {
      final groups = <ModifierGroup>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchModifierGroups(page: page);
        groups.addAll(result.groups);
        hasMore = result.hasMore;
        page += 1;
      }
      return groups;
    });
  }

  Future<Result<List<UnitOfMeasure>>> loadAllUnits({
    bool activeOnly = true,
  }) async {
    return Result.guard(() async {
      final units = <UnitOfMeasure>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchUnitsOfMeasure(
          page: page,
          active: activeOnly ? true : null,
        );
        units.addAll(result.units);
        hasMore = result.hasMore;
        page += 1;
      }
      units.sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
      return units;
    });
  }

  Future<Result<UnitOfMeasure>> createUnit(UnitOfMeasureDraft draft) async {
    return Result.guard(() => _service.createUnitOfMeasure(draft));
  }

  Future<Result<UnitOfMeasure>> updateUnit({
    required int id,
    required UnitOfMeasureDraft draft,
  }) async {
    return Result.guard(
      () => _service.updateUnitOfMeasure(id: id, changes: draft.toJson()),
    );
  }

  Future<Result<void>> deleteUnit(int id) async {
    return Result.guard(() => _service.deleteUnitOfMeasure(id));
  }

  /// Persists a new ordering by patching each unit's display_order to its index.
  Future<Result<void>> reorderUnits(List<int> orderedUnitIds) async {
    return Result.guard(() async {
      for (var index = 0; index < orderedUnitIds.length; index += 1) {
        await _service.updateUnitOfMeasure(
          id: orderedUnitIds[index],
          changes: {'display_order': index},
        );
      }
    });
  }

  /// Asks the backend whether a SKU / barcode is still free.
  ///
  /// Drives the live "that barcode belongs to `<product>`" hint in the product
  /// and variant dialogs. Deliberately *not* routed through [resolveBarcode]:
  /// that lookup is cached, POS-shaped, and blind to archived products, whose
  /// codes are still claimed at the unique index.
  Future<Result<CatalogIdentityCheck>> checkVariantIdentity({
    String sku = '',
    String barcode = '',
    int? excludeVariantId,
  }) {
    return Result.guard(
      () => _service.checkVariantIdentity(
        sku: sku,
        barcode: barcode,
        excludeVariantId: excludeVariantId,
      ),
    );
  }

  /// The shop's scale label layouts, ordered as the till must try them.
  ///
  /// Fails soft: a till that cannot reach the rules endpoint still rings every
  /// ordinary barcode. It simply stops recognising scale labels, which is the
  /// safe half of the failure — the alternative is reading a sticker with rules
  /// we are not sure of.
  Future<List<ScaleBarcodeRule>> activeScaleRules({
    bool refresh = false,
  }) async {
    final token = _domainToken(ServerStateDomain.scales);
    final cached = _scaleRulesCache.read(_singleton, token);
    if (!refresh && cached != null) {
      return cached;
    }
    try {
      final rules = orderScaleRules(await _service.fetchScaleBarcodeRules());
      _scaleRulesCache.write(_singleton, rules, token);
      return rules;
    } catch (_) {
      // Stale rules still read the label. Refusing the scan does not.
      return _scaleRulesCache.readStale(_singleton) ??
          const <ScaleBarcodeRule>[];
    }
  }

  /// The shop's unit registry, cached; empty while it is unreachable.
  ///
  /// Nothing it can do is worth failing a scan over, so every caller below
  /// falls back to the built-in unit codes rather than refusing to read a
  /// label.
  Future<Map<String, UnitOfMeasure>> _units() async {
    final token = _domainToken(ServerStateDomain.catalogDefs);
    final cached = _unitRegistryCache.read(_singleton, token);
    if (cached != null) {
      return cached;
    }
    try {
      final result = await loadAllUnits(activeOnly: false);
      if (result case Ok<List<UnitOfMeasure>>(:final value)) {
        final registry = {
          for (final unit in value) unit.code.trim().toLowerCase(): unit,
        };
        _unitRegistryCache.write(_singleton, registry, token);
        return registry;
      }
    } catch (_) {
      // Unreachable registry: the built-in codes still ring kilograms.
    }
    return _unitRegistryCache.readStale(_singleton) ??
        const <String, UnitOfMeasure>{};
  }

  /// Whether a product's base unit may be sold in fractions.
  ///
  /// The shop's own registry answers it, so a shop that defined "وزنة" as a
  /// weight unit behaves like one using the seeded kilogram.
  Future<bool> unitAllowsFractional(String code) async {
    final normalized = code.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    final unit = (await _units())[normalized];
    return unit?.allowsFractional ?? baseUnitAllowsFractional(normalized);
  }

  /// How many of [productUnit] are in one [valueUnit] — the factor that carries
  /// a scale label's measurement into the product's own unit.
  ///
  /// Null when they cannot be converted between, which the till reports rather
  /// than guessing at. Answered from the registry so a shop's own unit converts
  /// like a built-in one; the static tables stand in when it is unreachable.
  Future<double?> unitConversionFactorFor(
    String valueUnit,
    String productUnit,
  ) async {
    final source = valueUnit.trim().toLowerCase();
    final target = productUnit.trim().toLowerCase();
    if (source.isEmpty || target.isEmpty) {
      return null;
    }
    if (source == target) {
      return 1;
    }
    final units = await _units();
    final from = units[source];
    final to = units[target];
    if (from == null || to == null) {
      return unitConversionFactor(source, target);
    }
    final fromFactor = from.referenceFactor;
    final toFactor = to.referenceFactor;
    if (from.dimension != to.dimension ||
        fromFactor == null ||
        toFactor == null ||
        fromFactor <= 0 ||
        toFactor <= 0) {
      return null;
    }
    return fromFactor / toFactor;
  }

  /// Drop the cached rules so the next scan re-reads them. Called after an edit.
  void invalidateScaleRules() {
    _scaleRulesCache.clear();
    _unitRegistryCache.clear();
    _barcodeCache.clear();
  }

  /// Drop everything this repository has cached.
  ///
  /// For the one change no re-fetch can answer: the signed-in user's
  /// permissions moved. What they may see has changed, so nothing read under
  /// the old ones may survive to be shown under the new ones.
  void invalidateAll() {
    _barcodeCache.clear();
    _productPageCache.clear();
    _scaleRulesCache.clear();
    _unitRegistryCache.clear();
  }

  Future<Result<List<ScaleBarcodeRule>>> loadScaleBarcodeRules({
    bool activeOnly = false,
  }) async {
    return Result.guard(
      () => _service.fetchScaleBarcodeRules(activeOnly: activeOnly),
    );
  }

  Future<Result<ScaleBarcodeRule>> saveScaleBarcodeRule({
    int? id,
    required Map<String, Object?> draft,
  }) async {
    final result = await Result.guard(() async {
      final saved = id == null
          ? await _service.createScaleBarcodeRule(draft)
          : await _service.updateScaleBarcodeRule(id: id, changes: draft);
      return saved;
    });
    invalidateScaleRules();
    return result;
  }

  Future<Result<void>> deleteScaleBarcodeRule(int id) async {
    final result = await Result.guard(
      () => _service.deleteScaleBarcodeRule(id),
    );
    invalidateScaleRules();
    return result;
  }

  /// Resolves a scanned code to the variant it rings up — and, when the code
  /// is a packaging (unit) barcode, to the matched [ProductUnit] so the caller
  /// adds a carton line instead of a piece.
  Future<Result<BarcodeResolution?>> resolveBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return const Ok(null);
    }

    // Burst scans of the same item (multi-quantity rings, rescans) skip the
    // network entirely. Not-found is cached too — a mistyped code rescanned
    // in frustration is the hottest lookup of all. Never caches errors.
    final cacheKey = '${activeOnly ? 'active' : 'all'}:$normalizedBarcode';
    final cached = _barcodeCache.read(cacheKey, _service.catalogVersionToken);
    if (cached != null) {
      return Ok(cached.resolution);
    }

    final result = await Result.guard(() async {
      final direct = await _resolveByExactBarcode(
        normalizedBarcode,
        activeOnly: activeOnly,
      );
      if (direct != null) {
        return direct;
      }
      // A weighing scale's own label: the catalog holds the item's short code
      // (or the masked base code), never the sticker with the weight in it, so
      // retry with the candidates the matched rule produces.
      final scaleBarcode = parseScaleBarcode(
        normalizedBarcode,
        await activeScaleRules(),
      );
      if (scaleBarcode == null) {
        return null;
      }
      for (final candidate in scaleBarcode.candidateBarcodes) {
        final resolution = await _resolveByExactBarcode(
          candidate,
          activeOnly: activeOnly,
        );
        if (resolution != null) {
          // Carried on the resolution so the till reads the sticker once.
          return resolution.copyWith(scaleMatch: scaleBarcode);
        }
      }
      return null;
    });
    if (result is Ok<BarcodeResolution?>) {
      _barcodeCache.write(
        cacheKey,
        BarcodeResolutionHit(result.value),
        _service.catalogVersionToken,
      );
    }
    return result;
  }

  /// Legacy shape of [resolveBarcode] for flows that only handle plain variant
  /// barcodes (stock count, catalog jump). A packaging barcode resolves to
  /// null here — counting or editing "one piece" for a carton scan would be
  /// silently wrong.
  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    final result = await resolveBarcode(barcode, activeOnly: activeOnly);
    return switch (result) {
      Ok<BarcodeResolution?>(:final value) => Ok(
        value == null || value.isUnitBarcode ? null : value.variant,
      ),
      Error<BarcodeResolution?>(:final exception) => Error(exception),
    };
  }

  Future<BarcodeResolution?> _resolveByExactBarcode(
    String barcode, {
    required bool activeOnly,
  }) async {
    final page = await _service.fetchProductVariants(
      query: ProductQuery(
        barcode: barcode,
        availability: activeOnly
            ? ProductAvailabilityFilter.active
            : ProductAvailabilityFilter.all,
      ),
      page: 1,
    );
    for (final variant in page.variants) {
      if (variant.barcode.trim() == barcode) {
        return BarcodeResolution(variant: variant);
      }
    }
    // No variant owns the code, but the endpoint also matches packaging (unit)
    // barcodes — find the unit carrying it and ring it up against the
    // product's default variant.
    for (final variant in page.variants) {
      final units = variant.productDetail?.units ?? const <ProductUnit>[];
      for (final unit in units) {
        if (!unit.barcodes.contains(barcode)) {
          continue;
        }
        final siblings = page.variants.where(
          (candidate) => candidate.productId == variant.productId,
        );
        final target = siblings.firstWhere(
          (candidate) => candidate.isDefault,
          orElse: () => variant,
        );
        return BarcodeResolution(variant: target, unit: unit);
      }
    }
    return null;
  }

  List<ProductVariant> sampleProductVariants(ProductQuery query) {
    final variants = const [
      ProductVariant(
        id: 1,
        productId: 1,
        productName: 'قهوة البيت',
        displayName: 'قهوة البيت',
        fullName: 'قهوة البيت',
        sku: 'COF-001',
        unitPrice: 3.50,
        barcode: '1000001',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 2,
        productId: 2,
        productName: 'شاي بالنعناع',
        displayName: 'شاي بالنعناع',
        fullName: 'شاي بالنعناع',
        sku: 'TEA-001',
        unitPrice: 2.75,
        barcode: '1000002',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 3,
        productId: 3,
        productName: 'لوح تمر',
        displayName: 'لوح تمر',
        fullName: 'لوح تمر',
        sku: 'SNK-012',
        unitPrice: 1.95,
        barcode: '1000003',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 4,
        productId: 4,
        productName: 'كرواسون زعتر',
        displayName: 'كرواسون زعتر',
        fullName: 'كرواسون زعتر',
        sku: 'BKR-044',
        unitPrice: 4.25,
        barcode: '1000004',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 5,
        productId: 5,
        productName: 'عصير برتقال',
        displayName: 'عصير برتقال',
        fullName: 'عصير برتقال',
        sku: 'JCE-002',
        unitPrice: 3.25,
        barcode: '1000005',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 6,
        productId: 6,
        productName: 'ساندويتش حلومي',
        displayName: 'ساندويتش حلومي',
        fullName: 'ساندويتش حلومي',
        sku: 'SND-019',
        unitPrice: 6.80,
        barcode: '1000006',
        quantityOnHand: 12,
        isDefault: true,
      ),
    ];

    final search = query.search.trim().toLowerCase();
    final barcode = query.barcode.trim();
    final filtered = variants
        .where((variant) {
          final matchesSearch =
              search.isEmpty ||
              variant.displayLabel.toLowerCase().contains(search) ||
              variant.productName.toLowerCase().contains(search) ||
              variant.sku.toLowerCase().contains(search) ||
              variant.barcode.toLowerCase().contains(search);
          final matchesBarcode = barcode.isEmpty || variant.barcode == barcode;
          return matchesSearch && matchesBarcode;
        })
        .toList(growable: false);

    final sorted = [...filtered];
    sorted.sort((a, b) {
      return switch (query.ordering) {
        ProductOrdering.name => a.displayLabel.compareTo(b.displayLabel),
        // Sample data carries no popularity signal; fall back to A–Z. The live
        // path sorts server-side, so real "most bought" ordering is unaffected.
        ProductOrdering.mostBought => a.displayLabel.compareTo(b.displayLabel),
        ProductOrdering.priceAsc => a.unitPrice.compareTo(b.unitPrice),
        ProductOrdering.priceDesc => b.unitPrice.compareTo(a.unitPrice),
        ProductOrdering.newest => b.id.compareTo(a.id),
      };
    });
    return sorted;
  }

  List<Product> sampleProducts(ProductQuery query) {
    if (query.categories.isEmpty) {
      return sampleProductVariants(
        query,
      ).map(Product.fromVariant).toList(growable: false);
    }
    return const [];
  }
}

/// Wraps a barcode resolution so a cached "not found" (null resolution) stays
/// distinguishable from a cache miss.
class BarcodeResolutionHit {
  const BarcodeResolutionHit(this.resolution);

  final BarcodeResolution? resolution;
}
