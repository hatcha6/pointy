import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/esim/esim_device.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/pill.dart';

/// Says whether this phone takes eSIMs: quiet when it does, and when nobody
/// can tell. It only ever warns: the customer can still buy, for this phone
/// if they know better, or for someone else's.
class EsimSupportBanner extends StatelessWidget {
  const EsimSupportBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final compatibility = CardsScope.of(context).esimCompatibility;
    return ValueListenableBuilder(
      valueListenable: compatibility.support,
      builder: (context, support, _) {
        if (support == EsimSupport.unknown) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final supported = support == EsimSupport.yes;
        // Good news stays small; only the warning takes a panel.
        if (supported) {
          return Padding(
            padding: const EdgeInsets.only(bottom: CardsSpace.lg),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Pill(
                  text: l10n.esimPhoneSupported,
                  tone: PillTone.success,
                  icon: Icons.check_circle_rounded,
                ),
              ),
            ),
          );
        }
        final foreground = supported
            ? scheme.tertiary
            : scheme.onSecondaryContainer;
        return Padding(
          padding: const EdgeInsets.only(bottom: CardsSpace.lg),
          child: Container(
            padding: const EdgeInsets.all(CardsSpace.md),
            decoration: BoxDecoration(
              color: supported
                  ? scheme.tertiary.withValues(alpha: 0.1)
                  : scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(CardsRadii.tile),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  supported ? Icons.check_circle_rounded : Icons.info_rounded,
                  size: 22,
                  color: foreground,
                ),
                const SizedBox(width: CardsSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        supported
                            ? l10n.esimPhoneSupported
                            : l10n.esimPhoneNotSupported,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                        ),
                      ),
                      if (!supported) ...[
                        const SizedBox(height: 2),
                        Text(
                          l10n.esimPhoneNotSupportedBody,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
