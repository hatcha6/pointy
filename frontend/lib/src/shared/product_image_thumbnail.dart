import 'package:flutter/material.dart';

import 'design/design.dart';

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
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: PointyColors.primaryContainer),
          child: url.isEmpty
              ? _FallbackLabel(text: fallbackText)
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      _FallbackLabel(text: fallbackText),
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) {
                      return child;
                    }
                    return Center(
                      child: SizedBox.square(
                        dimension: size * 0.28,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  },
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
