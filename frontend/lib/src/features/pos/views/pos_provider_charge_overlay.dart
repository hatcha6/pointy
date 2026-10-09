import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';

/// Covers the till while a provider is performing what the sale sold —
/// airtime, a bill, a card — which can take over a minute.
///
/// The sale is recorded and the cart already cleared, so without this the
/// till would look idle and ready for the next customer while the result of
/// the last one is still on its way. It says what is happening, counts the
/// seconds, and swallows every tap: the one thing to do is wait.
class PosProviderChargeOverlay extends StatefulWidget {
  const PosProviderChargeOverlay({super.key, required this.startedAt});

  /// When the provider was asked; null counts from now.
  final DateTime? startedAt;

  @override
  State<PosProviderChargeOverlay> createState() =>
      _PosProviderChargeOverlayState();
}

class _PosProviderChargeOverlayState extends State<PosProviderChargeOverlay> {
  /// The seconds that had already passed when this was first drawn, then one
  /// more for every tick: counted, not read off the clock, so what is on
  /// screen is exactly how long the cashier has been looking at it.
  late int _seconds = DateTime.now()
      .difference(widget.startedAt ?? DateTime.now())
      .inSeconds
      .clamp(0, 86400);
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _seconds++);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Stack(
      key: const ValueKey('provider_charge_overlay'),
      children: [
        const ModalBarrier(dismissible: false, color: Color(0x99000000)),
        Center(
          child: Semantics(
            liveRegion: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(PointyRadii.card + 4),
                    border: Border.all(color: colors.line),
                    boxShadow: [
                      BoxShadow(
                        color: colors.shadow.withValues(alpha: 0.25),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 22,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox.square(
                          dimension: 38,
                          child: PointySpinner(),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.posProviderChargingTitle,
                          key: const ValueKey('provider_charge_title'),
                          textAlign: TextAlign.center,
                          style: textTheme.titleMedium?.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.posProviderChargingBody,
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.mutedInk,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.posProviderChargingSeconds(_seconds),
                          key: const ValueKey('provider_charge_seconds'),
                          style: PointyTypography.numeric(
                            (textTheme.titleSmall ?? const TextStyle())
                                .copyWith(
                                  color: colors.primaryStrong,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
