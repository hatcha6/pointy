import 'package:flutter/material.dart';

import '../../../data/models/voucher_menu.dart';
import '../../../shared/design/design.dart';
import '../../../shared/flags/bundled_flags.dart';

/// A country's flag in a small rounded frame with a hairline border — or its
/// ISO code in the same frame when there is none.
///
/// The flag ships inside the app (`assets/flags/`), so nothing is downloaded;
/// a country the build has no flag for falls back to the bytes the menu
/// carried, if any. Never an emoji flag: a Windows till cannot draw one.
class VoucherCountryFlag extends StatelessWidget {
  const VoucherCountryFlag({
    super.key,
    required this.country,
    this.width = 24,
    this.height = 16,
    this.semanticLabel,
  });

  final VoucherCountry country;
  final double width;
  final double height;

  /// What a screen reader says; null when a visible name sits beside it.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final radius = BorderRadius.circular(height <= 12 ? 2 : 3);
    final bytes = country.flag;
    final code = _CodeFallback(code: country.code);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (width * dpr).ceil();
    final bundled = bundledFlagCodes.contains(country.code.toUpperCase());

    final flag = Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: colors.subtleFill, borderRadius: radius),
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: colors.ink.withValues(alpha: 0.18),
          width: 0.8,
        ),
      ),
      child: bundled
          ? Image.asset(
              bundledFlagAsset(country.code),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              cacheWidth: cacheWidth,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => code,
            )
          : bytes == null
          ? code
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              cacheWidth: cacheWidth,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => code,
            ),
    );

    final label = semanticLabel;
    if (label == null) {
      return ExcludeSemantics(child: flag);
    }
    return Semantics(label: label, image: true, child: flag);
  }
}

class _CodeFallback extends StatelessWidget {
  const _CodeFallback({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: FittedBox(
          child: Text(
            code.isEmpty ? '—' : code,
            textDirection: TextDirection.ltr,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.mutedInk,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
