import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/card_art.dart';
import '../../shared/pill.dart';
import '../../core/analytics/analytics.dart';
import '../../shared/name_text.dart';
import 'card_qr.dart';
import 'holo_foil.dart';
import 'scratch_off.dart';

/// The surface of a bought card's back, in the brand's own colours.
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
  const _CodeText({required this.code, required this.used});

  final String code;
  final bool used;

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
          style: PointyTypography.numeric(theme.textTheme.headlineMedium!)
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

/// The brand's name across the top of the back, and the used mark.
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
          child: NameText(
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

/// The card's back, the only design it has, on the page and on the pass
/// alike: the QR under its foil, the name beside it, and the code in full
/// across the bottom, large enough to read out and type.
///
/// [qrScratched] is the foil's scratch, as [ScratchOff] takes it: 0 whole, 1
/// the QR bare.
class CodeCardFace extends StatelessWidget {
  const CodeCardFace({
    super.key,
    required this.brand,
    required this.palette,
    required this.code,
    required this.used,
    required this.qrScratched,
    this.onTap,
  });

  final CardBrand brand;

  /// The back's colours: the art's own.
  final ArtPalette palette;
  final String code;
  final bool used;
  final Animation<double> qrScratched;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // The code itself never shows in a session replay, nor does its QR.
    return Sensitive(
      child: _BrandBack(
        palette: palette,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: ScratchOff(
                      progress: qrScratched,
                      radius: CardsRadii.tile,
                      cover: HoloFoil(
                        radius: CardsRadii.tile,
                        label: l10n.showQr,
                      ),
                      child: _QrTile(
                        brand: brand,
                        ink: palette.dark,
                        code: code,
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
                        _amberBar,
                        Expanded(
                          // What to do with the foil, then what to do with
                          // what was under it.
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FadeTransition(
                                opacity: qrScratched.drive(
                                  Tween<double>(begin: 1, end: 0).chain(
                                    CurveTween(curve: const Interval(0, 0.2)),
                                  ),
                                ),
                                child: _ScanHint(text: l10n.qrRevealHint),
                              ),
                              FadeTransition(
                                opacity: qrScratched.drive(
                                  CurveTween(curve: const Interval(0.7, 1)),
                                ),
                                child: _ScanHint(text: l10n.qrScanHint),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          l10n.secretCode,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: CardsSpace.xs),
            _CodeText(code: code, used: used),
          ],
        ),
      ),
    );
  }
}

/// How to use the QR, in as many whole lines as the room left on the back.
class _ScanHint extends StatelessWidget {
  const _ScanHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Colors.white70);
    final line =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 12) *
        (style?.height ?? 1.4);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxHeight - CardsSpace.xs;
        final lines = (room / line).floor().clamp(0, 3);
        if (lines == 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: CardsSpace.xs),
          child: Text(
            text,
            maxLines: lines,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        );
      },
    );
  }
}

/// The code for a camera to read: a white tile, as a scanner wants dark on
/// light.
class _QrTile extends StatelessWidget {
  const _QrTile({required this.brand, required this.ink, required this.code});

  final CardBrand brand;
  final Color ink;
  final String code;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CardsRadii.tile),
      ),
      child: Padding(
        // The quiet margin a scanner finds the code's edge by.
        padding: const EdgeInsets.all(CardsSpace.sm + 2),
        child: CardQr(
          brand: brand,
          ink: ink,
          code: code,
          label: AppLocalizations.of(context).showQr,
        ),
      ),
    );
  }
}
