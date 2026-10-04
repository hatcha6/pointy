import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import 'components/pointy_progress.dart';
import 'network_image_caching.dart';

/// Opens [imageUrls] full screen: pinch/scroll/double-tap to zoom, swipe or
/// arrow keys between images, Escape or a tap on the backdrop to close.
Future<void> showProductImageViewer(
  BuildContext context, {
  required List<String> imageUrls,
  int initialIndex = 0,
  String? title,
}) {
  final urls = [
    for (final url in imageUrls)
      if (url.trim().isNotEmpty) url.trim(),
  ];
  if (urls.isEmpty) return Future.value();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context)!.closeButton,
    barrierColor: Colors.black,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => ProductImageViewer(
      imageUrls: urls,
      initialIndex: initialIndex.clamp(0, urls.length - 1),
      title: title,
    ),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class ProductImageViewer extends StatefulWidget {
  const ProductImageViewer({
    super.key,
    required this.imageUrls,
    this.initialIndex = 0,
    this.title,
  });

  final List<String> imageUrls;
  final int initialIndex;
  final String? title;

  @override
  State<ProductImageViewer> createState() => _ProductImageViewerState();
}

class _ProductImageViewerState extends State<ProductImageViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.imageUrls.length) return;
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final count = widget.imageUrls.length;
    // In RTL the PageView runs right-to-left, so the left arrow moves forward.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final title = widget.title?.trim() ?? '';

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _step(rtl ? 1 : -1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _step(rtl ? -1 : 1),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.black,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: count,
                onPageChanged: (index) => setState(() {
                  _index = index;
                  _zoomed = false;
                }),
                itemBuilder: (context, index) => _ZoomableImage(
                  url: widget.imageUrls[index],
                  onZoomChanged: (zoomed) {
                    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
                  },
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      IconButton.filledTonal(
                        tooltip: l10n.closeButton,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: Colors.white),
                        ),
                      ),
                      if (count > 1)
                        Text(
                          '${_index + 1} / $count',
                          textDirection: TextDirection.ltr,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: Colors.white70),
                        ),
                    ],
                  ),
                ),
              ),
              if (count > 1) ...[
                _StepButton(
                  alignment: AlignmentDirectional.centerStart,
                  icon: Icons.chevron_left,
                  tooltip: l10n.productImageViewerPrevious,
                  visible: _index > 0,
                  onPressed: () => _step(-1),
                ),
                _StepButton(
                  alignment: AlignmentDirectional.centerEnd,
                  icon: Icons.chevron_right,
                  tooltip: l10n.productImageViewerNext,
                  visible: _index < count - 1,
                  onPressed: () => _step(1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One page: the full-resolution image, zoomable, with a tap on the empty
/// backdrop closing the viewer.
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({required this.url, required this.onZoomChanged});

  final String url;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _transform = TransformationController();
  TapDownDetails? _doubleTap;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  bool get _isZoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  void _toggleZoom() {
    if (_isZoomed) {
      _transform.value = Matrix4.identity();
    } else {
      final focal = _doubleTap?.localPosition ?? Offset.zero;
      const scale = 2.5;
      _transform.value = Matrix4.diagonal3Values(
        scale,
        scale,
        1,
      )..setTranslationRaw(-focal.dx * (scale - 1), -focal.dy * (scale - 1), 0);
    }
    widget.onZoomChanged(_isZoomed);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).maybePop(),
      onDoubleTapDown: (details) => _doubleTap = details,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: 6,
        onInteractionEnd: (_) => widget.onZoomChanged(_isZoomed),
        child: SizedBox.expand(
          child: CachedNetworkImage(
            imageUrl: widget.url,
            cacheKey: stableImageCacheKey(widget.url),
            fit: BoxFit.contain,
            placeholder: (context, _) => const Center(child: PointySpinner()),
            errorWidget: (context, _, _) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 64,
                color: Colors.white54,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.visible,
    required this.onPressed,
  });

  final AlignmentDirectional alignment;
  final IconData icon;
  final String tooltip;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Visibility.maintain(
          visible: visible,
          child: IconButton.filledTonal(
            tooltip: tooltip,
            onPressed: onPressed,
            // Chevron icons mirror under RTL, so "start" still points back.
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }
}
