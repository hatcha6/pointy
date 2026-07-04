import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/price_lookup_result.dart';
import '../../../shared/design/design.dart';

/// The lifecycle of a single scan, from the customer's point of view.
enum PriceCheckerKioskStatus { idle, loading, found, notFound, disconnected }

/// The customer-facing price-checker screen — pure presentation.
///
/// All logic (scanning, network, auto-reset, PIN) lives in the screen that
/// wraps this; keeping the view stateless lets the preview harness drive every
/// state with seeded data and no backend.
///
/// Design goals (it sits on a shelf facing shoppers):
///  * **Legible at a glance** — type scales with the shortest screen edge and is
///    clamped so a tiny shelf verifier and a wall monitor both read cleanly.
///  * **Responsive** — stacks on tall/narrow displays, splits image|details on
///    wide ones.
///  * **On brand** — the دفتر logo sits on a light medallion so it stays crisp
///    on any background, in light or dark theme.
class PriceCheckerKioskView extends StatelessWidget {
  const PriceCheckerKioskView({
    super.key,
    required this.status,
    this.result,
    this.barcode = '',
    this.shopName = '',
    this.cameraPreview,
    this.onManualEntry,
    this.onExitRequested,
  });

  final PriceCheckerKioskStatus status;
  final PriceLookupResult? result;
  final String barcode;
  final String shopName;

  /// Live camera feed for hands-free scanning, or null when this device scans
  /// with a wedge scanner only. The view frames it in a viewfinder card while
  /// idle; the wrapping screen owns the camera itself (start/stop/detection).
  final Widget? cameraPreview;

  /// Opens manual barcode entry (touch devices without a wedge scanner).
  final VoidCallback? onManualEntry;

  /// Staff affordance to leave kiosk mode (guarded by a PIN upstream).
  final VoidCallback? onExitRequested;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.page, colors.surfaceSunken],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final metrics = _KioskMetrics.of(constraints.biggest);
              return Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.all(metrics.gap * 1.2),
                      child: _buildContent(context, metrics),
                    ),
                  ),
                  _CornerControls(
                    metrics: metrics,
                    onManualEntry: onManualEntry,
                    onExitRequested: onExitRequested,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, _KioskMetrics metrics) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.03),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: switch (status) {
        PriceCheckerKioskStatus.found => _FoundContent(
          key: ValueKey('found-${result?.barcode}-${result?.sku}'),
          result: result!,
          shopName: shopName,
          metrics: metrics,
        ),
        PriceCheckerKioskStatus.notFound => _MessageContent(
          key: const ValueKey('not-found'),
          metrics: metrics,
          icon: Icons.search_off_rounded,
          tone: _MessageTone.warning,
          title: AppLocalizations.of(context)!.priceCheckerNotFoundTitle,
          subtitle: barcode.isEmpty
              ? AppLocalizations.of(context)!.priceCheckerNotFoundBody
              : AppLocalizations.of(context)!.priceCheckerScannedCode(barcode),
        ),
        PriceCheckerKioskStatus.disconnected => _MessageContent(
          key: const ValueKey('disconnected'),
          metrics: metrics,
          icon: Icons.wifi_off_rounded,
          tone: _MessageTone.danger,
          title: AppLocalizations.of(context)!.priceCheckerDisconnectedTitle,
          subtitle: AppLocalizations.of(context)!.priceCheckerDisconnectedBody,
        ),
        // With a camera, idle and loading share one child key so the switcher
        // updates it in place — remounting would flicker the live preview.
        PriceCheckerKioskStatus.loading => _IdleContent(
          key: ValueKey(cameraPreview != null ? 'camera-scan' : 'loading'),
          metrics: metrics,
          shopName: shopName,
          isLoading: true,
          cameraPreview: cameraPreview,
        ),
        PriceCheckerKioskStatus.idle => _IdleContent(
          key: ValueKey(cameraPreview != null ? 'camera-scan' : 'idle'),
          metrics: metrics,
          shopName: shopName,
          isLoading: false,
          cameraPreview: cameraPreview,
        ),
      },
    );
  }
}

/// Derived sizing for the current viewport. Everything the kiosk renders is a
/// function of the shortest edge so it scales smoothly from ~3" verifiers to
/// large monitors, with hard clamps that guarantee legibility at the extremes.
class _KioskMetrics {
  const _KioskMetrics({
    required this.size,
    required this.scale,
    required this.isWide,
    required this.gap,
  });

  final Size size;
  final double scale;
  final bool isWide;
  final double gap;

  factory _KioskMetrics.of(Size size) {
    final shortest = math.min(size.width, size.height);
    // 420 ≈ a typical small tablet; clamp keeps tiny + huge screens sane.
    final scale = (shortest / 420).clamp(0.62, 2.6).toDouble();
    final isWide = size.width >= 760 && size.width > size.height * 1.15;
    return _KioskMetrics(
      size: size,
      scale: scale,
      isWide: isWide,
      gap: (16 * scale).clamp(10, 40).toDouble(),
    );
  }

  double font(double base, {double min = 0, double max = double.infinity}) =>
      (base * scale).clamp(min == 0 ? base * 0.62 : min, max).toDouble();
}

/// The دفتر logo on a light medallion so it stays crisp on any background.
class _BrandMedallion extends StatelessWidget {
  const _BrandMedallion({required this.diameter, this.elevated = true});

  final double diameter;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      width: diameter,
      height: diameter,
      padding: EdgeInsets.all(diameter * 0.18),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: 0.16),
                  blurRadius: diameter * 0.12,
                  offset: Offset(0, diameter * 0.05),
                ),
              ]
            : null,
      ),
      child: Image.asset(
        'assets/branding/logo.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

/// Idle (and loading) state: brand medallion + prompt, then either a live
/// camera viewfinder (camera scanning) or a gentle scan pulse (wedge scanner).
class _IdleContent extends StatelessWidget {
  const _IdleContent({
    super.key,
    required this.metrics,
    required this.shopName,
    required this.isLoading,
    this.cameraPreview,
  });

  final _KioskMetrics metrics;
  final String shopName;
  final bool isLoading;
  final Widget? cameraPreview;

  @override
  Widget build(BuildContext context) {
    final preview = cameraPreview;
    if (preview != null) {
      return _buildCameraLayout(context, preview);
    }
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _BrandMedallion(diameter: (metrics.scale * 132).clamp(96, 280)),
            SizedBox(height: metrics.gap * 1.4),
            if (shopName.isNotEmpty) ...[
              Text(
                shopName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: metrics.font(26, min: 18, max: 56),
                  fontWeight: FontWeight.w700,
                  color: colors.ink,
                  height: 1.1,
                ),
              ),
              SizedBox(height: metrics.gap * 0.6),
            ],
            Text(
              l10n.priceCheckerScanPrompt,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: metrics.font(20, min: 15, max: 38),
                fontWeight: FontWeight.w500,
                color: colors.mutedInk,
                height: 1.3,
              ),
            ),
            SizedBox(height: metrics.gap * 1.6),
            _ScanPulse(
              width: (metrics.scale * 220).clamp(160, 460),
              height: (metrics.scale * 74).clamp(56, 150),
              active: !isLoading,
            ),
            if (isLoading) ...[
              SizedBox(height: metrics.gap * 1.4),
              SizedBox(
                width: metrics.font(28, min: 22, max: 44),
                height: metrics.font(28, min: 22, max: 44),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: colors.primary,
                ),
              ),
              SizedBox(height: metrics.gap),
              Text(
                l10n.priceCheckerLoading,
                style: TextStyle(
                  fontSize: metrics.font(16, min: 13, max: 28),
                  color: colors.mutedInk,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Camera scanning is hands-free, so the live viewfinder is the hero: the
  /// shopper aims the barcode using the preview as feedback. Branding sits
  /// beside it on wide displays and above it on tall ones.
  Widget _buildCameraLayout(BuildContext context, Widget preview) {
    final l10n = AppLocalizations.of(context)!;

    final branding = _CameraBranding(metrics: metrics, shopName: shopName);
    final size = _viewfinderSize();
    final viewfinder = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size.width,
          height: size.height,
          child: _CameraViewfinder(
            preview: preview,
            metrics: metrics,
            isLoading: isLoading,
          ),
        ),
        SizedBox(height: metrics.gap * 0.6),
        // Fixed-height slot so the loading line fades in without any reflow.
        SizedBox(
          height: metrics.font(16, min: 13, max: 28) * 1.5,
          child: AnimatedOpacity(
            opacity: isLoading ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Text(
              l10n.priceCheckerLoading,
              style: TextStyle(
                fontSize: metrics.font(16, min: 13, max: 28),
                color: context.pointyColors.mutedInk,
              ),
            ),
          ),
        ),
      ],
    );

    if (metrics.isWide) {
      return Row(
        children: [
          Expanded(
            flex: 5,
            child: Center(child: SingleChildScrollView(child: branding)),
          ),
          SizedBox(width: metrics.gap * 1.6),
          Expanded(flex: 6, child: Center(child: viewfinder)),
        ],
      );
    }

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            branding,
            SizedBox(height: metrics.gap * 1.2),
            viewfinder,
          ],
        ),
      ),
    );
  }

  /// The viewfinder fills the space branding leaves over: roughly the trailing
  /// half on wide displays, the lower ~40% on tall ones, always clamped so the
  /// preview stays generous on a wall monitor and sane on a shelf verifier.
  Size _viewfinderSize() {
    if (metrics.isWide) {
      final height = (metrics.size.height * 0.58).clamp(180.0, 540.0);
      final width = math.min(height * 4 / 3, metrics.size.width * 0.46);
      return Size(width, height.toDouble());
    }
    final width = math.min(
      metrics.size.width - metrics.gap * 4,
      (metrics.scale * 340).clamp(240.0, 640.0),
    );
    final height = math.min(width * 0.75, metrics.size.height * 0.4);
    return Size(width.toDouble(), height.toDouble());
  }
}

/// The branding block shown next to the camera viewfinder: medallion, shop
/// name, and the aim-at-the-camera prompt.
class _CameraBranding extends StatelessWidget {
  const _CameraBranding({required this.metrics, required this.shopName});

  final _KioskMetrics metrics;
  final String shopName;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BrandMedallion(diameter: (metrics.scale * 100).clamp(72, 220)),
        SizedBox(height: metrics.gap),
        if (shopName.isNotEmpty) ...[
          Text(
            shopName,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: metrics.font(24, min: 17, max: 50),
              fontWeight: FontWeight.w700,
              color: colors.ink,
              height: 1.1,
            ),
          ),
          SizedBox(height: metrics.gap * 0.5),
        ],
        Text(
          l10n.priceCheckerCameraScanPrompt,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: metrics.font(18, min: 14, max: 34),
            fontWeight: FontWeight.w500,
            color: colors.mutedInk,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

/// The live preview framed as a viewfinder: a rounded elevated card (same
/// treatment as the product photo) with corner brackets and a sweeping scan
/// line, so it reads as "hold your barcode here" without any instructions.
class _CameraViewfinder extends StatefulWidget {
  const _CameraViewfinder({
    required this.preview,
    required this.metrics,
    required this.isLoading,
  });

  final Widget preview;
  final _KioskMetrics metrics;
  final bool isLoading;

  @override
  State<_CameraViewfinder> createState() => _CameraViewfinderState();
}

class _CameraViewfinderState extends State<_CameraViewfinder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final metrics = widget.metrics;
    return Container(
      decoration: BoxDecoration(
        // Black backdrop keeps the card looking intentional while the camera
        // warms up or shows a letterboxed feed.
        color: Colors.black,
        borderRadius: BorderRadius.circular(metrics.gap * 1.4),
        border: Border.all(color: colors.line),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.14),
            blurRadius: metrics.gap * 1.4,
            offset: Offset(0, metrics.gap * 0.5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.preview,
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) {
                return CustomPaint(
                  painter: _ViewfinderOverlayPainter(
                    bracketColor: Colors.white.withValues(alpha: 0.9),
                    sweepColor: colors.primary,
                    sweep: widget.isLoading ? -1 : _sweep.value,
                  ),
                );
              },
            ),
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: widget.isLoading ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: ColoredBox(
                color: Colors.black38,
                child: Center(
                  child: SizedBox(
                    width: metrics.font(30, min: 24, max: 48),
                    height: metrics.font(30, min: 24, max: 48),
                    child: const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Corner brackets + the sweeping scan line drawn over the camera feed.
class _ViewfinderOverlayPainter extends CustomPainter {
  _ViewfinderOverlayPainter({
    required this.bracketColor,
    required this.sweepColor,
    required this.sweep,
  });

  final Color bracketColor;
  final Color sweepColor;

  /// 0..1 sweep position, or negative to hide the line (while loading).
  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = math.min(size.width, size.height);
    final inset = shortest * 0.09;
    final arm = shortest * 0.14;
    final paint = Paint()
      ..color = bracketColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = (shortest * 0.014).clamp(2.0, 4.0)
      ..strokeCap = StrokeCap.round;

    for (final (dx, dy) in const [(1, 1), (-1, 1), (1, -1), (-1, -1)]) {
      final corner = Offset(
        dx > 0 ? inset : size.width - inset,
        dy > 0 ? inset : size.height - inset,
      );
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx + arm * dx, corner.dy)
          ..lineTo(corner.dx, corner.dy)
          ..lineTo(corner.dx, corner.dy + arm * dy),
        paint,
      );
    }

    if (sweep >= 0) {
      final y = inset * 1.6 + (size.height - inset * 3.2) * sweep;
      final glow = Paint()
        ..shader =
            LinearGradient(
              colors: [
                sweepColor.withValues(alpha: 0),
                sweepColor.withValues(alpha: 0.85),
                sweepColor.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromLTWH(inset, y - 10, size.width - inset * 2, 20),
            );
      canvas.drawRect(
        Rect.fromLTWH(inset, y - 1.5, size.width - inset * 2, 3),
        glow,
      );
    }
  }

  @override
  bool shouldRepaint(_ViewfinderOverlayPainter oldDelegate) =>
      oldDelegate.sweep != sweep ||
      oldDelegate.bracketColor != bracketColor ||
      oldDelegate.sweepColor != sweepColor;
}

/// A barcode glyph with a sweeping highlight line — a quiet "ready to scan" cue.
class _ScanPulse extends StatefulWidget {
  const _ScanPulse({
    required this.width,
    required this.height,
    required this.active,
  });

  final double width;
  final double height;
  final bool active;

  @override
  State<_ScanPulse> createState() => _ScanPulseState();
}

class _ScanPulseState extends State<_ScanPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _BarcodePainter(
              color: colors.ink.withValues(alpha: 0.78),
              sweepColor: colors.primary,
              sweep: widget.active ? _controller.value : -1,
            ),
          );
        },
      ),
    );
  }
}

class _BarcodePainter extends CustomPainter {
  _BarcodePainter({
    required this.color,
    required this.sweepColor,
    required this.sweep,
  });

  final Color color;
  final Color sweepColor;
  final double sweep;

  // A fixed, pleasant-looking bar pattern (relative widths).
  static const _bars = <double>[
    3,
    1,
    1,
    2,
    1,
    3,
    1,
    1,
    2,
    1,
    1,
    3,
    2,
    1,
    1,
    1,
    2,
    3,
    1,
    1,
    2,
    1,
    3,
    1,
    1,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final total = _bars.fold<double>(0, (sum, w) => sum + w) * 2 - 1;
    final unit = size.width / total;
    final paint = Paint()..color = color;
    var x = 0.0;
    for (var i = 0; i < _bars.length; i++) {
      final w = _bars[i] * unit;
      if (i.isEven) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 0, w, size.height),
            Radius.circular(unit * 0.4),
          ),
          paint,
        );
      }
      x += w + unit;
    }

    if (sweep >= 0) {
      final y = size.height * sweep;
      final glow = Paint()
        ..shader = LinearGradient(
          colors: [
            sweepColor.withValues(alpha: 0),
            sweepColor.withValues(alpha: 0.9),
            sweepColor.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, y - 12, size.width, 24));
      canvas.drawRect(Rect.fromLTWH(0, y - 2, size.width, 4), glow);
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter oldDelegate) =>
      oldDelegate.sweep != sweep || oldDelegate.color != color;
}

/// The result of a successful scan: photo (if any), name, price + discounts.
class _FoundContent extends StatelessWidget {
  const _FoundContent({
    super.key,
    required this.result,
    required this.shopName,
    required this.metrics,
  });

  final PriceLookupResult result;
  final String shopName;
  final _KioskMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final hasImage = result.hasImage;
    // Details are start-aligned ONLY when they sit beside the photo (wide +
    // image). With no photo, the details fill the width and must be centred —
    // otherwise start-alignment hugs the right edge on this RTL layout.
    final alongsidePhoto = metrics.isWide && hasImage;
    final details = _ProductDetails(
      result: result,
      metrics: metrics,
      centered: !alongsidePhoto,
    );

    final Widget core;
    if (alongsidePhoto) {
      // Wide displays: photo on the leading side, details trailing.
      core = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: _ProductPhoto(url: result.imageUrl, metrics: metrics),
          ),
          SizedBox(width: metrics.gap * 1.6),
          Expanded(flex: 6, child: details),
        ],
      );
    } else {
      core = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasImage) ...[
            Flexible(
              child: Center(
                child: _ProductPhoto(url: result.imageUrl, metrics: metrics),
              ),
            ),
            SizedBox(height: metrics.gap * 1.2),
          ],
          details,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MiniBrandBar(shopName: shopName, metrics: metrics),
        SizedBox(height: metrics.gap),
        Expanded(child: Center(child: core)),
      ],
    );
  }
}

class _ProductPhoto extends StatelessWidget {
  const _ProductPhoto({required this.url, required this.metrics});

  final String url;
  final _KioskMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final side = metrics.isWide
        ? (metrics.size.height * 0.66).clamp(180.0, 560.0)
        : (metrics.scale * 200).clamp(140.0, 420.0);
    return Container(
      constraints: BoxConstraints(maxWidth: side, maxHeight: side),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(metrics.gap * 1.4),
        border: Border.all(color: colors.line),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.12),
            blurRadius: metrics.gap * 1.4,
            offset: Offset(0, metrics.gap * 0.5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1,
        child: Image.network(
          url,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: colors.primary,
                ),
              ),
            );
          },
          errorBuilder: (context, _, __) => Icon(
            Icons.inventory_2_outlined,
            size: side * 0.4,
            color: colors.mutedInk.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

class _ProductDetails extends StatelessWidget {
  const _ProductDetails({
    required this.result,
    required this.metrics,
    this.centered = false,
  });

  final PriceLookupResult result;
  final _KioskMetrics metrics;

  /// Centre every line (name, price, pills, hint). Set when the details fill
  /// the width with no photo beside them; false only in the wide photo|details
  /// split, where start-alignment reads correctly next to the image.
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final crossAxis = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final textAlign = centered ? TextAlign.center : TextAlign.start;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxis,
      children: [
        Text(
          result.productName,
          textAlign: textAlign,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: metrics.font(30, min: 20, max: 64),
            fontWeight: FontWeight.w700,
            color: colors.ink,
            height: 1.15,
          ),
        ),
        if (result.showsVariant) ...[
          SizedBox(height: metrics.gap * 0.4),
          Text(
            result.variantName,
            textAlign: textAlign,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: metrics.font(18, min: 13, max: 34),
              fontWeight: FontWeight.w500,
              color: colors.mutedInk,
            ),
          ),
        ],
        SizedBox(height: metrics.gap * 1.2),
        _PriceBlock(result: result, metrics: metrics, align: crossAxis),
        SizedBox(height: metrics.gap * 1.1),
        Wrap(
          spacing: metrics.gap * 0.6,
          runSpacing: metrics.gap * 0.5,
          alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          children: [
            _StockPill(inStock: result.inStock, metrics: metrics),
            if (result.sku.isNotEmpty)
              _InfoPill(
                icon: Icons.qr_code_2_rounded,
                label: result.sku,
                metrics: metrics,
              ),
          ],
        ),
        SizedBox(height: metrics.gap * 1.2),
        Align(
          alignment: centered
              ? Alignment.center
              : AlignmentDirectional.centerStart,
          child: Text(
            l10n.priceCheckerScanAnother,
            style: TextStyle(
              fontSize: metrics.font(15, min: 12, max: 24),
              color: colors.mutedInk,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _PriceBlock extends StatelessWidget {
  const _PriceBlock({
    required this.result,
    required this.metrics,
    required this.align,
  });

  final PriceLookupResult result;
  final _KioskMetrics metrics;
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final discounted = result.hasDiscount;
    final priceColor = discounted ? colors.primaryStrong : colors.ink;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: align,
      children: [
        if (discounted) ...[
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: metrics.gap * 0.6,
            runSpacing: metrics.gap * 0.3,
            children: [
              Text(
                result.originalPriceDisplay,
                style: TextStyle(
                  fontSize: metrics.font(22, min: 15, max: 40),
                  color: colors.mutedInk,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: colors.mutedInk,
                  decorationThickness: 2,
                ),
              ),
              _SaveBadge(
                label: result.discountPercent > 0
                    ? l10n.priceCheckerSavePercent('${result.discountPercent}')
                    : l10n.priceCheckerSaveAmount(result.discountTotal),
                metrics: metrics,
              ),
            ],
          ),
          SizedBox(height: metrics.gap * 0.5),
        ],
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            result.finalPriceDisplay,
            maxLines: 1,
            style: TextStyle(
              fontSize: metrics.font(56, min: 34, max: 132),
              fontWeight: FontWeight.w800,
              color: priceColor,
              height: 1.0,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _SaveBadge extends StatelessWidget {
  const _SaveBadge({required this.label, required this.metrics});

  final String label;
  final _KioskMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.gap * 0.7,
        vertical: metrics.gap * 0.35,
      ),
      decoration: BoxDecoration(
        color: colors.accentAmber,
        borderRadius: BorderRadius.circular(metrics.gap * 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_offer_rounded,
            size: metrics.font(16, min: 13, max: 26),
            color: Colors.white,
          ),
          SizedBox(width: metrics.gap * 0.3),
          Text(
            label,
            style: TextStyle(
              fontSize: metrics.font(16, min: 13, max: 28),
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _StockPill extends StatelessWidget {
  const _StockPill({required this.inStock, required this.metrics});

  final bool inStock;
  final _KioskMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final color = inStock ? colors.success : colors.warning;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.gap * 0.7,
        vertical: metrics.gap * 0.4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(metrics.gap * 1.5),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            inStock ? Icons.check_circle_rounded : Icons.remove_circle_rounded,
            size: metrics.font(16, min: 13, max: 26),
            color: color,
          ),
          SizedBox(width: metrics.gap * 0.35),
          Text(
            inStock ? l10n.priceCheckerInStock : l10n.priceCheckerOutOfStock,
            style: TextStyle(
              fontSize: metrics.font(15, min: 12, max: 26),
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.icon,
    required this.label,
    required this.metrics,
  });

  final IconData icon;
  final String label;
  final _KioskMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.gap * 0.7,
        vertical: metrics.gap * 0.4,
      ),
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(metrics.gap * 1.5),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: metrics.font(15, min: 12, max: 24),
            color: colors.mutedInk,
          ),
          SizedBox(width: metrics.gap * 0.35),
          Text(
            label,
            style: TextStyle(
              fontSize: metrics.font(14, min: 11, max: 22),
              fontWeight: FontWeight.w600,
              color: colors.mutedInk,
            ),
          ),
        ],
      ),
    );
  }
}

/// A slim brand strip kept at the top of a result so دفتر stays present without
/// stealing focus from the product.
class _MiniBrandBar extends StatelessWidget {
  const _MiniBrandBar({required this.shopName, required this.metrics});

  final String shopName;
  final _KioskMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _BrandMedallion(
          diameter: (metrics.scale * 44).clamp(34, 80),
          elevated: false,
        ),
        if (shopName.isNotEmpty) ...[
          SizedBox(width: metrics.gap * 0.6),
          Flexible(
            child: Text(
              shopName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: metrics.font(18, min: 14, max: 30),
                fontWeight: FontWeight.w700,
                color: colors.ink,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

enum _MessageTone { warning, danger }

class _MessageContent extends StatelessWidget {
  const _MessageContent({
    super.key,
    required this.metrics,
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
  });

  final _KioskMetrics metrics;
  final IconData icon;
  final _MessageTone tone;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final color = switch (tone) {
      _MessageTone.warning => colors.warning,
      _MessageTone.danger => colors.danger,
    };
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: (metrics.scale * 120).clamp(88, 240),
              height: (metrics.scale * 120).clamp(88, 240),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: (metrics.scale * 60).clamp(44, 120),
                color: color,
              ),
            ),
            SizedBox(height: metrics.gap * 1.4),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: metrics.font(28, min: 19, max: 52),
                fontWeight: FontWeight.w700,
                color: colors.ink,
                height: 1.15,
              ),
            ),
            SizedBox(height: metrics.gap * 0.7),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: metrics.font(18, min: 14, max: 32),
                color: colors.mutedInk,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Low-key corner affordances: a staff exit lock (long-press) and an optional
/// manual-entry button for touch devices without a wedge scanner.
class _CornerControls extends StatelessWidget {
  const _CornerControls({
    required this.metrics,
    required this.onManualEntry,
    required this.onExitRequested,
  });

  final _KioskMetrics metrics;
  final VoidCallback? onManualEntry;
  final VoidCallback? onExitRequested;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return Stack(
      children: [
        if (onExitRequested != null)
          PositionedDirectional(
            top: metrics.gap * 0.4,
            start: metrics.gap * 0.4,
            // Tap opens the exit PIN dialog — the PIN is the real guard, so a
            // curious customer tap only shows a locked keypad that dismisses
            // itself. (Long-press kept for staff used to the old gesture.)
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onExitRequested,
              onLongPress: onExitRequested,
              child: Tooltip(
                message: l10n.priceCheckerExitTooltip,
                child: Padding(
                  padding: EdgeInsets.all(metrics.gap * 0.6),
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: (metrics.scale * 22).clamp(18, 34),
                    color: colors.mutedInk.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ),
          ),
        if (onManualEntry != null)
          PositionedDirectional(
            bottom: metrics.gap * 0.4,
            end: metrics.gap * 0.4,
            child: TextButton.icon(
              onPressed: onManualEntry,
              icon: Icon(
                Icons.keyboard_alt_outlined,
                size: (metrics.scale * 20).clamp(16, 30),
              ),
              label: Text(l10n.priceCheckerManualEntry),
              style: TextButton.styleFrom(
                foregroundColor: colors.mutedInk,
                textStyle: TextStyle(
                  fontSize: metrics.font(14, min: 12, max: 22),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
