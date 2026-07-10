import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'design/design.dart';
import 'network_image_caching.dart';

class ProductImageThumbnail extends StatelessWidget {
  const ProductImageThumbnail({
    super.key,
    required this.imageUrl,
    required this.fallbackText,
    this.size = 56,
    this.borderRadius = 8,
  });

  final String? imageUrl;
  final String fallbackText;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    // Decode at the thumbnail's display resolution so a full-size source image
    // doesn't load into a small tile (memory + image-cache thrash on scroll).
    final cacheEdge = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.pointyColors.primaryContainer,
          ),
          child: url.isEmpty
              ? _FallbackLabel(text: fallbackText)
              : CachedNetworkImage(
                  imageUrl: url,
                  cacheKey: stableImageCacheKey(url),
                  fit: BoxFit.cover,
                  memCacheWidth: cacheEdge,
                  memCacheHeight: cacheEdge,
                  errorWidget: (context, imageUrl, error) =>
                      _FallbackLabel(text: fallbackText),
                  placeholder: (context, imageUrl) => Center(
                    child: SizedBox.square(
                      dimension: size * 0.28,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
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
    final label = text.trim().isEmpty ? '' : text.trim().characters.first;
    return Center(
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: context.pointyColors.primaryDark,
        ),
      ),
    );
  }
}
