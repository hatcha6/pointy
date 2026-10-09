import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../design/design.dart';
import '../network_image_caching.dart';

class PointyProductImageFrame extends StatelessWidget {
  const PointyProductImageFrame({
    super.key,
    required this.imageUrl,
    required this.fallbackText,
    this.width,
    this.height,
    this.borderRadius = PointyRadii.card,
    this.fit = BoxFit.contain,
    this.padding = const EdgeInsets.all(8),
    this.backgroundColor,
    this.border,
    this.fallback,
  });

  final String? imageUrl;
  final String fallbackText;
  final double? width;
  final double? height;
  final double borderRadius;
  final BoxFit fit;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final BoxBorder? border;

  /// Drawn instead of [fallbackText]'s initial when there is no image, while
  /// it loads, and when it fails — so a card's art keeps its look either way.
  final Widget? fallback;

  /// Dev only: draws an image URL from bytes instead of the network, for the
  /// preview harnesses and capture tests, which have no server to fetch
  /// product art from. Null — always, in the app — means every image comes
  /// off the network through the cache.
  static ImageProvider? Function(String url)? debugImageOverride;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    final fallback = this.fallback ?? _FallbackLabel(text: fallbackText);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor ?? context.pointyColors.subtleFill,
            border: border,
          ),
          child: url.isEmpty
              ? fallback
              : Padding(
                  padding: padding,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Decode at display resolution: a ~1000px source image in
                      // a small card tile otherwise wastes memory and thrashes
                      // the image cache on scroll. Cap by the larger finite
                      // dimension so aspect ratio is preserved (single axis).
                      final dpr = MediaQuery.devicePixelRatioOf(context);
                      final logical =
                          [
                                width ?? constraints.maxWidth,
                                height ?? constraints.maxHeight,
                              ]
                              .where((v) => v.isFinite && v > 0)
                              .fold<double>(0, (a, b) => a > b ? a : b);
                      final cacheWidth = logical > 0
                          ? (logical * dpr).round()
                          : null;
                      final override = debugImageOverride?.call(url);
                      if (override != null) {
                        return Image(
                          image: override,
                          fit: fit,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => fallback,
                        );
                      }
                      return CachedNetworkImage(
                        imageUrl: url,
                        cacheKey: stableImageCacheKey(url),
                        fit: fit,
                        memCacheWidth: cacheWidth,
                        errorWidget: (context, imageUrl, error) => fallback,
                        placeholder: (context, imageUrl) => fallback,
                      );
                    },
                  ),
                ),
        ),
      ),
    );
  }
}

class _FallbackLabel extends StatelessWidget {
  const _FallbackLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final trimmed = text.trim();
    final label = trimmed.isEmpty ? '' : trimmed.characters.first;

    return Center(
      child: Text(
        label,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: context.pointyColors.primaryStrong,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
