import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/components/pointy_status_pill.dart';
import '../../../../shared/design/design.dart';

/// «وضع تجريبي — لا يُرسل رصيد حقيقي ولا يُدفع شيء»: over every service screen
/// while the relay is buying from its test supplier. Nothing sent is real and
/// nothing paid is paid, so nobody may take a customer's money for it — the
/// banner is solid, full width and impossible to read past.
///
/// [compact] is the same banner for a header or a row of cards, where height
/// is short.
class ServiceTestModeBanner extends StatelessWidget {
  const ServiceTestModeBanner({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final background = colors.warning;
    final foreground =
        ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : const Color(0xFF241705);
    final style = (compact ? textTheme.bodySmall : textTheme.bodyMedium)
        ?.copyWith(color: foreground, fontWeight: FontWeight.w800, height: 1.3);
    return Semantics(
      container: true,
      liveRegion: false,
      child: DecoratedBox(
        key: const ValueKey('service_test_mode_banner'),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(PointyRadii.card),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.symmetric(
            horizontal: compact ? 10 : 14,
            vertical: compact ? 7 : 10,
          ),
          child: Row(
            children: [
              Icon(
                Icons.science_rounded,
                size: compact ? 20 : 24,
                color: foreground,
              ),
              SizedBox(width: compact ? 8 : 10),
              Expanded(
                child: Text(l10n.posServicesTestModeBanner, style: style),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «عملية تجريبية»: a small mark on a cart line, and on the success dialog, for
/// a service sold while the relay was in test mode.
class ServiceTestModeMark extends StatelessWidget {
  const ServiceTestModeMark({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyStatusPill(
      key: const ValueKey('service_test_mode_mark'),
      label: l10n.posServicesTestModeMark,
      icon: Icons.science_outlined,
      color: context.pointyColors.warning,
    );
  }
}
