import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/components/pointy_progress.dart';

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
    setState(() {});
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
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.xs,
        spacing.lg,
        spacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.stockCountSearchItem,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).deleteButtonTooltip,
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                    ),
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
        padding: EdgeInsets.all(32),
        child: Center(child: PointySpinner()),
      );
    }
    if (_hasError) {
      return _CenteredNote(
        icon: Icons.error_outline,
        message: l10n.stockCountLoadError,
      );
    }
    if (_results.isEmpty) {
      return _CenteredNote(
        icon: Icons.search_off,
        message: l10n.stockCountSearchEmpty,
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) => _ResultRow(variant: _results[index]),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.variant});

  final ProductVariant variant;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: InkWell(
        onTap: () => Navigator.of(context).pop(variant),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Padding(
          padding: EdgeInsets.all(spacing.sm),
          child: Row(
            children: [
              ProductImageThumbnail(
                imageUrl: variant.primaryImage?.contentUrl,
                fallbackText: variant.displayLabel,
                size: 44,
                borderRadius: 10,
              ),
              SizedBox(width: spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      variant.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (variant.sku.isNotEmpty)
                      Text(
                        variant.sku,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              Icon(Icons.add_circle_outline, color: colors.primaryStrong),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenteredNote extends StatelessWidget {
  const _CenteredNote({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: colors.lineStrong),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}
