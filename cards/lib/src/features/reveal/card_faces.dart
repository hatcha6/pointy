import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/card_art.dart';
import '../../shared/pill.dart';
import '../../core/analytics/analytics.dart';

/// The back of a bought card, in the brand's own colours: its name at the
/// top and the faces' content beneath. Both of the card's backs (the code,
/// and the code as a QR) are built on it, so they turn into each other as
/// the same card.
class _BrandBack extends StatelessWidget {
  const _BrandBack({required this.palette, required this.child, this.onTap});

  final ArtPalette palette;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ArtPalette(:light, :dark) = palette;
    return AspectRatio(
      aspectRatio: kCardAspect,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CardsRadii.tile),
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [light, dark],
            ),
            boxShadow: CardsShadows.hero,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CardsRadii.tile),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(CardsSpace.lg),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The code itself: left to right, one line, the card's own figures.
class _CodeText extends StatelessWidget {
  const _CodeText({required this.code, required this.used, this.style});

  final String code;
  final bool used;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.ltr,
      // One line always: a code broken across lines gets typed wrong. Long
      // ones scale down instead.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          code,
          maxLines: 1,
          style:
              PointyTypography.numeric(style ?? theme.textTheme.headlineMedium!)
                  .copyWith(
                    color: Colors.white,
                    letterSpacing: 2,
                    decoration: used ? TextDecoration.lineThrough : null,
                    decorationColor: Colors.white70,
                  ),
        ),
      ),
    );
  }
}

/// The brand's name across the top of a back, and the used mark.
class _BackTitle extends StatelessWidget {
  const _BackTitle({required this.brand, required this.used});

  final CardBrand brand;
  final bool used;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            brand.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (used)
          Pill(
            text: AppLocalizations.of(context).usedBadge,
            tone: PillTone.muted,
          ),
      ],
    );
  }
}

const _amberBar = SizedBox(
  height: 5,
  width: 56,
  child: ColoredBox(color: PointyColors.accentAmber),
);

/// The card's back with its code: the code's one home, large, tap to copy.
class CodeCardFace extends StatelessWidget {
  const CodeCardFace({
    super.key,
    required this.brand,
    required this.palette,
    required this.code,
    required this.used,
    this.onTap,
  });

  final CardBrand brand;

  /// The back's colours: the art's own.
  final ArtPalette palette;
  final String code;
  final bool used;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The code itself never shows in a session replay.
    return Sensitive(
      child: _BrandBack(
        palette: palette,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BackTitle(brand: brand, used: used),
            const Spacer(),
            Text(
              AppLocalizations.of(context).secretCode,
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 2),
            _CodeText(code: code, used: used),
            const SizedBox(height: CardsSpace.sm),
            _amberBar,
          ],
        ),
      ),
    );
  }
}

/// The card's back with its code as a QR, for a camera to read: on a white
/// tile (a scanner wants dark on light), its dots in the brand's own deep
/// colour with the brand's art at the centre, and the code written beside it
/// for anyone without a camera.
class QrCardFace extends StatelessWidget {
  const QrCardFace({
    super.key,
    required this.brand,
    required this.palette,
    required this.code,
    required this.used,
    this.onCopy,
  });

  final CardBrand brand;
  final ArtPalette palette;
  final String code;
  final bool used;
  final VoidCallback? onCopy;

  /// The brand mark's share of the QR's width. With the highest error
  /// correction (it survives about 30% of the code lost) this covers a
  /// small fraction of it, well clear of what scanners tolerate.
  static const double _markShare = 0.24;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final ink = palette.dark;
    // Nor does its QR, which is the code too.
    return Sensitive(
      child: _BrandBack(
        palette: palette,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(CardsRadii.tile),
                ),
                child: Padding(
                  // The quiet margin a scanner finds the code's edge by.
                  padding: const EdgeInsets.all(CardsSpace.sm + 2),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final mark = constraints.maxWidth * _markShare;
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          QrImageView(
                            data: code,
                            padding: EdgeInsets.zero,
                            backgroundColor: Colors.white,
                            errorCorrectionLevel: QrErrorCorrectLevel.H,
                            semanticsLabel: l10n.showQr,
                            eyeStyle: QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: ink,
                            ),
                            dataModuleStyle: QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.circle,
                              color: ink,
                            ),
                          ),
                          Container(
                            width: mark,
                            height: mark,
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(mark * 0.28),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(mark * 0.22),
                              child: CardArtImage(brand: brand),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: CardsSpace.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BackTitle(brand: brand, used: used),
                  const SizedBox(height: CardsSpace.xs),
                  Text(
                    l10n.qrScanHint,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const Spacer(),
                  Semantics(
                    button: onCopy != null,
                    label: l10n.copyAction,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onCopy,
                      child: _CodeText(
                        code: code,
                        used: used,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  const SizedBox(height: CardsSpace.sm),
                  _amberBar,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
