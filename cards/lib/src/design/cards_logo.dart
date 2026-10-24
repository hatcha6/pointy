import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

/// The «دفتر كروت» mark (concept أ: the card stack), with the word mark beside
/// it when [withName]: «دفتر» in ink, «كروت» in amber.
class CardsLogo extends StatelessWidget {
  const CardsLogo({super.key, this.size = 40, this.withName = false});

  final double size;
  final bool withName;

  static const AssetImage mark = AssetImage('assets/branding/cards_mark.png');

  @override
  Widget build(BuildContext context) {
    final image = Image(
      image: mark,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: withName ? null : AppLocalizations.of(context).appTitle,
    );
    if (!withName) {
      return image;
    }
    final theme = Theme.of(context);
    final words = AppLocalizations.of(context).appTitle.split(' ');
    final style = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      height: 1.1,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        image,
        SizedBox(width: size * 0.3),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: words.first),
              if (words.length > 1)
                TextSpan(
                  text: ' ${words.sublist(1).join(' ')}',
                  style: TextStyle(color: theme.colorScheme.secondary),
                ),
            ],
          ),
          style: style,
        ),
      ],
    );
  }
}
