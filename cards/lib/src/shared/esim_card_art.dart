import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/cards_tokens.dart';
import 'name_text.dart';

/// Puts the bundled flags on the app's licenses page, as their MIT licence asks.
void registerFlagLicense() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/flags/LICENSE');
    yield LicenseEntryWithLineBreaks(['circle-flags'], text);
  });
}

/// The category an eSIM's card brand wears, so the shared pages draw this art.
const esimCategory = 'esim';

const _deep = [Color(0xFF0F766E), Color(0xFF0A5A55), Color(0xFF06302F)];
const _amber = Color(0xFFF0A93C);

/// A destination's flag, from the app's own assets: there at once, offline. A
/// region or the world (no country), or a code with no flag, shows a globe.
class EsimFlag extends StatelessWidget {
  const EsimFlag({super.key, required this.country, this.width = 40});

  final String country;
  final double width;

  @override
  Widget build(BuildContext context) {
    final globe = _Globe(size: width);
    final code = country.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2}$').hasMatch(code)) {
      return globe;
    }
    return SizedBox.square(
      dimension: width,
      child: SvgPicture.asset(
        'assets/flags/$code.svg',
        width: width,
        height: width,
        errorBuilder: (_, _, _) => globe,
        // A soft disc while it reads, so no globe flashes before a flag.
        placeholderBuilder: (context) => DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
    );
  }
}

class _Globe extends StatelessWidget {
  const _Globe({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF14958A), Color(0xFF06302F)],
        ),
      ),
      child: CustomPaint(painter: _GlobePainter(alpha: 0.75)),
    ),
  );
}

/// Meridians and parallels inside the box's circle.
class _GlobePainter extends CustomPainter {
  const _GlobePainter({required this.alpha});

  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, radius * 0.05)
      ..color = Colors.white.withValues(alpha: alpha);
    canvas.drawCircle(centre, radius * 0.97, line);
    for (final squeeze in [0.0, 0.38, 0.76]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: centre,
          width: radius * 2 * squeeze,
          height: radius * 1.94,
        ),
        line,
      );
    }
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: centre, radius: radius * 0.97)),
    );
    for (final lat in [-0.5, 0.0, 0.5]) {
      canvas.drawLine(
        centre + Offset(-radius, radius * lat),
        centre + Offset(radius, radius * lat),
        line,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) => oldDelegate.alpha != alpha;
}

/// An eSIM as a card: the destination's flag as a great disc breaking out of the
/// corner, over the brand's deep teal and a faint globe, with a SIM's amber plate
/// and the destination's name. It fills whatever box it is given and scales with
/// it, from a checkout's thumbnail to the order page's card.
class EsimCardArt extends StatelessWidget {
  const EsimCardArt({
    super.key,
    required this.name,
    required this.country,
    this.caption = '',
    this.kicker = '',
  });

  final String name;
  final String country;

  /// A line under the name, when there is room for one.
  final String caption;

  /// A small line over the name: «هدية إلى».
  final String kicker;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final disc = math.min(height * 0.98, width * 0.62);
        final theme = Theme.of(context);
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: _deep,
              stops: [0, 0.55, 1],
            ),
          ),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // The globe behind the flag, a size larger: a halo of lines.
              PositionedDirectional(
                end: -disc * 0.36,
                top: (height - disc * 1.46) / 2,
                width: disc * 1.46,
                height: disc * 1.46,
                child: const CustomPaint(painter: _GlobePainter(alpha: 0.13)),
              ),
              PositionedDirectional(
                end: -disc * 0.13,
                top: (height - disc) / 2,
                width: disc,
                height: disc,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.9),
                      width: math.max(1.5, disc * 0.018),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x66001F1B),
                        blurRadius: disc * 0.14,
                        offset: Offset(0, disc * 0.04),
                      ),
                    ],
                  ),
                  child: EsimFlag(country: country, width: disc),
                ),
              ),
              PositionedDirectional(
                start: width * 0.06,
                top: height * 0.1,
                child: _Plate(size: math.max(10, height * 0.15)),
              ),
              if (name.isNotEmpty)
                PositionedDirectional(
                  start: width * 0.06,
                  end: disc * 0.92,
                  bottom: height * 0.1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (kicker.isNotEmpty)
                        Text(
                          kicker,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: const Color(0xFFF7C777),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: NameText(
                          name,
                          maxLines: 1,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: (height * 0.16).clamp(10, 30).toDouble(),
                          ),
                        ),
                      ),
                      if (caption.isNotEmpty)
                        Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A SIM's contact plate with "eSIM" beside it.
class _Plate extends StatelessWidget {
  const _Plate({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size * 1.25,
          height: size,
          child: CustomPaint(painter: _PlatePainter()),
        ),
        SizedBox(width: size * 0.4),
        // A name, written the one way everywhere.
        Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            'eSIM',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.82,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlatePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(size.height * 0.2)),
      Paint()..color = _amber,
    );
    final line = Paint()
      ..color = const Color(0xFF8A5A14).withValues(alpha: 0.6)
      ..strokeWidth = math.max(0.6, size.height * 0.05);
    canvas.drawLine(box.centerLeft, box.centerRight, line);
    for (final x in [size.width / 3, size.width * 2 / 3]) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
  }

  @override
  bool shouldRepaint(_PlatePainter oldDelegate) => false;
}

/// [EsimCardArt] as a page's banner, rounded and lifted.
class EsimHero extends StatelessWidget {
  const EsimHero({
    super.key,
    required this.name,
    required this.country,
    this.caption = '',
    this.kicker = '',
    this.height = 148,
  });

  final String name;
  final String country;
  final String caption;
  final String kicker;
  final double height;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(CardsRadii.card),
      boxShadow: CardsShadows.art,
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(CardsRadii.card),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: EsimCardArt(
          name: name,
          country: country,
          caption: caption,
          kicker: kicker,
        ),
      ),
    ),
  );
}
