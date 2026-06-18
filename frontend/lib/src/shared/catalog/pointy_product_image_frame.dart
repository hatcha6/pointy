import 'package:flutter/material.dart';

import '../design/design.dart';

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

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';

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
              ? _FallbackLabel(text: fallbackText)
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
                      return Image.network(
                        url,
                        fit: fit,
                        cacheWidth: cacheWidth,
                        errorBuilder: (context, error, stackTrace) {
                          return _FallbackLabel(text: fallbackText);
                        },
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) {
                            return child;
                          }
                          return _FallbackLabel(text: fallbackText);
                        },
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
