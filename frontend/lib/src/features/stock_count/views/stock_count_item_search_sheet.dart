import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/responsive/responsive.dart';

/// Search/browse fallback for unlabeled goods. Returns the selected variant or
/// null on dismiss. Service and made-to-order products (which carry no stock)
/// are filtered out.
Future<ProductVariant?> showStockCountItemSearchSheet(
  BuildContext context, {
  required CatalogRepository catalogRepository,
}) {
  return showAdaptiveModalBottomSheet<ProductVariant>(
    context: context,
    builder: (context) =>
        _ItemSearchSheet(catalogRepository: catalogRepository),
  );
}

class _ItemSearchSheet extends StatefulWidget {
  const _ItemSearchSheet({required this.catalogRepository});

  final CatalogRepository catalogRepository;

  @override
  State<_ItemSearchSheet> createState() => _ItemSearchSheetState();
}

class _ItemSearchSheetState extends State<_ItemSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<ProductVariant> _results = const [];
  bool _isLoading = false;
  bool _hasError = false;
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String value) async {
    final token = ++_requestToken;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    final result = await widget.catalogRepository.loadProductVariants(
      query: ProductQuery(
        search: value.trim(),
        availability: ProductAvailabilityFilter.active,
      ),
      page: 1,
    );
    if (!mounted || token != _requestToken) {
      return;
    }
    setState(() {
      _isLoading = false;
      switch (result) {
        case Ok<ProductVariantPage>():
          _results = result.value.variants
              .where((variant) => !variant.isService && !variant.isPrepared)
              .toList(growable: false);
        case Error<ProductVariantPage>():
          _results = const [];
          _hasError = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.md,
        spacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.stockCountSearchHint,
            ),
          ),
          SizedBox(height: spacing.sm),
          Flexible(child: _buildResults(context, l10n)),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context, AppLocalizations l10n) {
    if (_isLoading && _results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_hasError) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(l10n.stockCountLoadError)),
      );
    }
    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(l10n.stockCountSearchEmpty)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final variant = _results[index];
        return ListTile(
          leading: ProductImageThumbnail(
            imageUrl: variant.primaryImage?.contentUrl,
            fallbackText: variant.displayLabel,
            size: 44,
          ),
          title: Text(variant.displayLabel),
          subtitle: variant.sku.isEmpty ? null : Text(variant.sku),
          onTap: () => Navigator.of(context).pop(variant),
        );
      },
    );
  }
}
