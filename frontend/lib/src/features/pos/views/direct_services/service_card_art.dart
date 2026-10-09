import 'package:flutter/material.dart';

import '../../../../data/models/service_kinds.dart';
import '../../../../data/models/voucher_menu.dart';
import '../../../../shared/design/design.dart';
import '../voucher_card_art.dart';

/// Which service a card is for: the airtime, or one type of bill.
enum ServiceCardKind { airtime, electricity, water, tv, internet }

/// The card a menu entry is drawn as; null for a type the till has no card for.
ServiceCardKind? serviceCardKindOf(VoucherMenuService service) {
  if (service.kind == ServiceKind.airtime) {
    return ServiceCardKind.airtime;
  }
  return switch (service.billType) {
    BillType.electricity => ServiceCardKind.electricity,
    BillType.water => ServiceCardKind.water,
    BillType.tv => ServiceCardKind.tv,
    BillType.internet => ServiceCardKind.internet,
    _ => null,
  };
}

BillType? billTypeOfCard(ServiceCardKind kind) => switch (kind) {
  ServiceCardKind.airtime => null,
  ServiceCardKind.electricity => BillType.electricity,
  ServiceCardKind.water => BillType.water,
  ServiceCardKind.tv => BillType.tv,
  ServiceCardKind.internet => BillType.internet,
};

/// A service card's art: a gradient in the service's own hue — a different
/// one for each, so a row of them reads at a glance — with a large pictogram
/// drawn on it. Light and dark follow the palette. 16:10, like a gift card.
class ServiceCardArt extends StatelessWidget {
  const ServiceCardArt({
    super.key,
    required this.kind,
    this.radius = 12,
    this.muted = false,
  });

  final ServiceCardKind kind;
  final double radius;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final tone = HSLColor.fromColor(switch (kind) {
      ServiceCardKind.airtime => colors.primary,
      ServiceCardKind.electricity => colors.accentAmber,
      ServiceCardKind.water => colors.paymentCard,
      ServiceCardKind.tv => colors.paymentTransfer,
      ServiceCardKind.internet => colors.paymentCash,
    });
    final saturated = tone.withSaturation(tone.saturation.clamp(0.5, 0.8));
    final light = saturated.withLightness(muted ? 0.46 : 0.42).toColor();
    final deep = saturated.withLightness(muted ? 0.30 : 0.24).toColor();
    final shape = BorderRadius.circular(radius);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: shape),
      foregroundDecoration: BoxDecoration(
        borderRadius: shape,
        border: Border.all(color: colors.ink.withValues(alpha: 0.10)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : constraints.maxWidth / kVoucherArtAspectRatio;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: AlignmentDirectional.topStart,
                end: AlignmentDirectional.bottomEnd,
                colors: [light, deep],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.9, -1.1),
                      radius: 1.1,
                      colors: [
                        Colors.white.withValues(alpha: 0.24),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
                PositionedDirectional(
                  end: -height * 0.30,
                  bottom: -height * 0.55,
                  child: _Ring(diameter: height * 1.25, alpha: 0.10),
                ),
                PositionedDirectional(
                  end: -height * 0.02,
                  bottom: -height * 0.78,
                  child: _Ring(diameter: height * 1.05, alpha: 0.07),
                ),
                ..._pictogram(height),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _pictogram(double h) {
    const white = Colors.white;
    final gold = const Color(0xFFFFD866);
    Widget icon(
      IconData data,
      double size, {
      Color color = white,
      double alpha = 1,
    }) => Icon(
      data,
      size: size,
      color: color.withValues(alpha: alpha),
    );

    switch (kind) {
      case ServiceCardKind.airtime:
        return [
          // The world, faint, behind; the phone in front, a bolt over it.
          PositionedDirectional(
            end: h * 0.06,
            top: h * 0.08,
            child: icon(Icons.public_rounded, h * 0.78, alpha: 0.20),
          ),
          Center(child: icon(Icons.smartphone_rounded, h * 0.66)),
          Align(
            alignment: const AlignmentDirectional(0.30, -0.12),
            child: icon(Icons.bolt_rounded, h * 0.42, color: gold),
          ),
        ];
      case ServiceCardKind.electricity:
        return [
          PositionedDirectional(
            end: h * 0.10,
            bottom: h * 0.06,
            child: icon(Icons.bolt_rounded, h * 0.60, alpha: 0.16),
          ),
          Center(child: icon(Icons.lightbulb_rounded, h * 0.66, color: gold)),
        ];
      case ServiceCardKind.water:
        return [
          PositionedDirectional(
            start: h * 0.10,
            bottom: h * 0.10,
            child: icon(Icons.water_drop_rounded, h * 0.26, alpha: 0.30),
          ),
          PositionedDirectional(
            end: h * 0.14,
            top: h * 0.14,
            child: icon(Icons.water_drop_rounded, h * 0.20, alpha: 0.26),
          ),
          Center(child: icon(Icons.water_drop_rounded, h * 0.68)),
        ];
      case ServiceCardKind.tv:
        return [
          Center(child: icon(Icons.tv_rounded, h * 0.72)),
          Align(
            alignment: const AlignmentDirectional(0, -0.12),
            child: icon(Icons.play_arrow_rounded, h * 0.30, color: gold),
          ),
        ];
      case ServiceCardKind.internet:
        return [
          PositionedDirectional(
            end: h * 0.06,
            top: h * 0.08,
            child: icon(Icons.language_rounded, h * 0.74, alpha: 0.18),
          ),
          Center(child: icon(Icons.wifi_rounded, h * 0.68)),
        ];
    }
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.diameter, required this.alpha});

  final double diameter;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: alpha * 2),
          width: diameter * 0.06,
        ),
        color: Colors.white.withValues(alpha: alpha * 0.4),
      ),
    );
  }
}
