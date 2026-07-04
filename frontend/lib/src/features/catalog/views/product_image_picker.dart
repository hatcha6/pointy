import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/attachment_summary.dart';
import '../../../data/models/product_image_search_result.dart';
import '../../../data/models/product_image_upload.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/design/design.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_image_thumbnail.dart';

const _productImageSearchPageSize = 30;

sealed class ProductImageSelection {
  const ProductImageSelection();

  ProductImageUpload? get upload => null;
  String? get importToken => null;
  String get label;
}

class UploadedProductImageSelection extends ProductImageSelection {
  const UploadedProductImageSelection(this.upload);

  @override
  final ProductImageUpload upload;

  @override
  String get label => upload.filename;
}

class SearchedProductImageSelection extends ProductImageSelection {
  const SearchedProductImageSelection(this.result);

  final ProductImageSearchResult result;

  @override
  String get importToken => result.importToken;

  @override
  String get label => result.displayTitle;
}

class ProductImageField extends StatelessWidget {
  const ProductImageField({
    super.key,
    required this.catalogRepository,
    required this.initialSearchQuery,
    required this.selection,
    required this.onChanged,
    this.currentImage,
    this.enabled = true,
    this.isSaving = false,
    this.imagePicker,
  });

  final CatalogRepository catalogRepository;
  final String initialSearchQuery;
  final AttachmentSummary? currentImage;
  final ProductImageSelection? selection;
  final ValueChanged<ProductImageSelection?> onChanged;
  final bool enabled;
  final bool isSaving;

  /// Injectable for tests; defaults to a real [ImagePicker] at capture time.
  final ImagePicker? imagePicker;

  /// Camera capture is offered on mobile and the web; desktop image_picker has
  /// no camera source, so the button is hidden there rather than failing.
  bool get _cameraSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final selected = selection;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ProductImagePreview(
              selection: selected,
              currentImage: currentImage,
              fallbackText: initialSearchQuery,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.productImageLabel,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    selected?.label ??
                        currentImage?.originalFilename ??
                        l10n.productImageEmpty,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: enabled && !isSaving
                            ? () => _pickLocalImage(context)
                            : null,
                        icon: const Icon(Icons.upload_file_outlined),
                        label: Text(l10n.productImageUploadButton),
                      ),
                      if (_cameraSupported)
                        OutlinedButton.icon(
                          onPressed: enabled && !isSaving
                              ? () => _captureFromCamera(context)
                              : null,
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: Text(l10n.productImageCameraButton),
                        ),
                      OutlinedButton.icon(
                        onPressed: enabled && !isSaving
                            ? () => _searchInternet(context)
                            : null,
                        icon: const Icon(Icons.travel_explore_outlined),
                        label: Text(l10n.productImageSearchButton),
                      ),
                      if (selected != null)
                        TextButton.icon(
                          onPressed: enabled && !isSaving
                              ? () => onChanged(null)
                              : null,
                          icon: const Icon(Icons.close),
                          label: Text(l10n.productImageClearSelectionButton),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickLocalImage(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.productImagePickError)));
      }
      return;
    }
    onChanged(
      UploadedProductImageSelection(
        ProductImageUpload(
          filename: file.name,
          bytes: bytes,
          contentType: _contentTypeForFile(file),
        ),
      ),
    );
  }

  Future<void> _captureFromCamera(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final XFile? photo;
    try {
      photo = await (imagePicker ?? ImagePicker()).pickImage(
        source: ImageSource.camera,
        // Cap the long edge so a full-resolution camera photo doesn't balloon
        // the upload; image_picker re-encodes to JPEG when imageQuality is set.
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
    } on Exception {
      // No camera on this platform/browser, or permission was denied.
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.productImageCameraUnavailable)),
        );
      return;
    }
    if (photo == null) {
      return; // The user backed out of the camera.
    }
    final bytes = await photo.readAsBytes();
    if (bytes.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.productImagePickError)));
      return;
    }
    onChanged(
      UploadedProductImageSelection(
        ProductImageUpload(
          filename: _cameraFilename(photo),
          bytes: bytes,
          contentType: _contentTypeForName(photo.name, photo.mimeType),
        ),
      ),
    );
  }

  Future<void> _searchInternet(BuildContext context) async {
    final picked = await showModalBottomSheet<ProductImageSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.84,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: ProductImageSearchSheet(
                catalogRepository: catalogRepository,
                initialQuery: initialSearchQuery,
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) {
      onChanged(picked);
    }
  }
}

class ProductImageSearchSheet extends StatefulWidget {
  const ProductImageSearchSheet({
    super.key,
    required this.catalogRepository,
    required this.initialQuery,
  });

  final CatalogRepository catalogRepository;
  final String initialQuery;

  @override
  State<ProductImageSearchSheet> createState() =>
      _ProductImageSearchSheetState();
}

class _ProductImageSearchSheetState extends State<ProductImageSearchSheet> {
  late final TextEditingController _searchController;
  List<ProductImageSearchResult> _results = [];
  var _isLoadingInitial = false;
  var _isLoadingMore = false;
  var _hasMoreResults = false;
  var _page = 1;
  String? _errorKey;

  bool get _isSearching => _isLoadingInitial || _isLoadingMore;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_searchController.text.trim().length >= 2) {
        _search(reset: true);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: context.pointyColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.travel_explore_outlined,
                  color: context.pointyColors.primaryStrong,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.productImageSearchTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      labelText: l10n.productImageSearchQueryLabel,
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _search(reset: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isSearching ? null : () => _search(reset: true),
                  icon: _isSearching
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(l10n.productImageSearchSubmitButton),
                ),
              ],
            ),
            if (_errorKey != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorText(l10n),
                style: TextStyle(color: context.pointyColors.danger),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(child: _buildResults(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 760
            ? 4
            : constraints.maxWidth >= 520
            ? 3
            : 2;
        return InfiniteScrollGrid<ProductImageSearchResult>(
          items: _results,
          onLoadMore: () => _search(reset: false),
          hasMore: _hasMoreResults,
          isLoadingInitial: _isLoadingInitial,
          isLoadingMore: _isLoadingMore,
          emptyBuilder: (context) =>
              Center(child: Text(l10n.productImageSearchEmpty)),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.88,
          ),
          itemBuilder: (context, result) {
            return _ImageResultTile(
              result: result,
              onTap: () => Navigator.of(
                context,
              ).pop(SearchedProductImageSelection(result)),
            );
          },
        );
      },
    );
  }

  Future<void> _search({required bool reset}) async {
    if (_isSearching) {
      return;
    }

    final query = _searchController.text.trim();
    if (query.length < 2) {
      setState(() {
        _errorKey = 'short';
        _hasMoreResults = false;
      });
      return;
    }

    setState(() {
      _errorKey = null;
      if (reset) {
        _page = 1;
        _results = [];
        _hasMoreResults = true;
        _isLoadingInitial = true;
      } else {
        _isLoadingMore = true;
      }
    });

    final result = await widget.catalogRepository.searchProductImages(
      query: query,
      page: _page,
      pageSize: _productImageSearchPageSize,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<ProductImageSearchResult>>():
        setState(() {
          _results = reset ? result.value : [..._results, ...result.value];
          _page += 1;
          _hasMoreResults = result.value.length >= _productImageSearchPageSize;
          _isLoadingInitial = false;
          _isLoadingMore = false;
        });
      case Error<List<ProductImageSearchResult>>():
        setState(() {
          _errorKey = 'failed';
          _hasMoreResults = false;
          _isLoadingInitial = false;
          _isLoadingMore = false;
        });
    }
  }

  String _errorText(AppLocalizations l10n) {
    return switch (_errorKey) {
      'short' => l10n.productImageSearchShortQuery,
      _ => l10n.productImageSearchError,
    };
  }
}

class _ImageResultTile extends StatelessWidget {
  const _ImageResultTile({required this.result, required this.onTap});

  final ProductImageSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Image.network(
                result.thumbnailUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Icons.broken_image_outlined, color: colors.line),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    result.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductImagePreview extends StatelessWidget {
  const _ProductImagePreview({
    required this.selection,
    required this.currentImage,
    required this.fallbackText,
  });

  final ProductImageSelection? selection;
  final AttachmentSummary? currentImage;
  final String fallbackText;

  @override
  Widget build(BuildContext context) {
    final selected = selection;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox.square(
        dimension: 88,
        child: switch (selected) {
          UploadedProductImageSelection(:final upload) => Image.memory(
            upload.bytes,
            fit: BoxFit.cover,
          ),
          SearchedProductImageSelection(:final result) => Image.network(
            result.thumbnailUrl,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => ProductImageThumbnail(
              imageUrl: currentImage?.contentUrl,
              fallbackText: fallbackText,
              size: 88,
            ),
          ),
          null => ProductImageThumbnail(
            imageUrl: currentImage?.contentUrl,
            fallbackText: fallbackText,
            size: 88,
          ),
        },
      ),
    );
  }
}

String _contentTypeForFile(PlatformFile file) {
  final extension = (file.extension ?? '').toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    _ => 'image/jpeg',
  };
}

String _cameraFilename(XFile photo) {
  final name = photo.name.trim();
  if (name.isNotEmpty && name.contains('.')) {
    return name;
  }
  return 'camera-${DateTime.now().millisecondsSinceEpoch}.jpg';
}

String _contentTypeForName(String name, String? mimeType) {
  if (mimeType != null && mimeType.startsWith('image/')) {
    return mimeType;
  }
  final dot = name.lastIndexOf('.');
  final extension = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  return switch (extension) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}
