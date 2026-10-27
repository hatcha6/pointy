import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../l10n/generated/app_localizations.dart';
import '../design/cards_tokens.dart';

enum PillTone { promo, muted, info, success, warning, danger, web }

/// A small capsule label: a badge on a card, an order's status.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.text,
    this.tone = PillTone.info,
    this.icon,
  });

  final String text;
  final PillTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      PillTone.promo => (PointyColors.accentAmber, PointyColors.ink),
      PillTone.muted => (const Color(0xCC101828), Colors.white),
      PillTone.info => (scheme.primaryContainer, scheme.onPrimaryContainer),
      PillTone.success => (
        scheme.tertiary.withValues(alpha: 0.14),
        scheme.tertiary,
      ),
      PillTone.warning => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      PillTone.danger => (scheme.error.withValues(alpha: 0.12), scheme.error),
      // Light frosted white over any card art, like the store's own badge.
      PillTone.web => (const Color(0xEBFFFFFF), PointyColors.ink),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(CardsRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// «على الموقع»: a card this build lists but sells on the website only.
class WebOnlyPill extends StatelessWidget {
  const WebOnlyPill({super.key, this.onArt = true});

  /// Frosted white over a card's art; tinted on the page itself, where
  /// white would vanish.
  final bool onArt;

  @override
  Widget build(BuildContext context) => Pill(
    text: AppLocalizations.of(context).webOnlyBadge,
    tone: onArt ? PillTone.web : PillTone.info,
    icon: Icons.language_rounded,
  );
}
