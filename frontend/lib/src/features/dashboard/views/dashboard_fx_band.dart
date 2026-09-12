import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/exchange_rate.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/dashboard_fx_view_model.dart';

/// The exchange-rate band: what the dinar is worth this morning.
///
/// A full-width strip of ticker tiles directly under the headline numbers,
/// because in Libya the parallel-market dollar is the second number a shop
/// owner looks at after their own takings — it sets what their next container
/// of stock will cost. One tile per tracked currency, each carrying the rate,
/// which way it has moved, and **how old it is**: a rate shown without its age
/// is the same mistake as a total shown without its currency.
///
/// It disappears entirely when the shop has no rates to show. Nothing here is
/// ever a placeholder — no rate is seeded at install, so every number on screen
/// was published by the feed or typed by the owner.
class DashboardFxBand extends StatefulWidget {
  const DashboardFxBand({
    super.key,
    required this.viewModel,
    this.onOpenRates,
    this.leadingGap = 0,
  });

  final DashboardFxViewModel viewModel;

  /// Space above the band when it draws. Owned here rather than by the caller
  /// so that a shop with no rates gets no band *and* no gap where one would be.
  final double leadingGap;

  /// Opens the full exchange-rates page — every currency, the history, and the
  /// place to type a rate the shop actually paid. Null when unavailable.
  final VoidCallback? onOpenRates;

  @override
  State<DashboardFxBand> createState() => _DashboardFxBandState();
}

class _DashboardFxBandState extends State<DashboardFxBand> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.viewModel.hasLoaded) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        // Nothing at all until we know — no skeleton, no reserved space. The
        // band is optional furniture, and holding room for furniture that may
        // never arrive makes the whole dashboard jump on load.
        if (!viewModel.hasLoaded || !viewModel.isVisible) {
          return const SizedBox.shrink();
        }

        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        final colors = context.pointyColors;
        final rates = viewModel.tracked;
        final substituted = rates.where((rate) => rate.isSubstituted).toList();

        return Padding(
          padding: EdgeInsetsDirectional.only(top: widget.leadingGap),
          child: PointyDetailSection(
            title: l10n.dashboardExchangeRatesTitle,
            icon: Icons.currency_exchange,
            trailing: _HeaderPills(
              rates: viewModel.rates,
              onOpenRates: widget.onOpenRates,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RateLayout(
                  rates: rates,
                  trendFor: viewModel.trendFor,
                  gap: spacing.sm,
                ),
                // A rate resolved off a settlement series the shop does not
                // use is the quiet costing error the whole feature exists to
                // prevent, so it is spelled out here rather than left to the
                // settings page.
                if (substituted.isNotEmpty) ...[
                  SizedBox(height: spacing.sm),
                  Text(
                    l10n.exchangeRateSubstitutedWarning(
                      _instrumentLabel(l10n, substituted.first.instrument),
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.warning),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Tiles side by side while each still has room to breathe; stacked rate-board
/// rows once they do not.
///
/// Three tiles across a phone leaves about 110px each, and the first thing that
/// gets squeezed out is the currency code — the one part of a tile that is not
/// negotiable. A stacked row has the whole width instead, and reads the way a
/// rate board on a wall does: which currency, how it is moving, what it costs.
class _RateLayout extends StatelessWidget {
  const _RateLayout({
    required this.rates,
    required this.trendFor,
    required this.gap,
  });

  final List<ResolvedRate> rates;
  final List<double> Function(String code) trendFor;
  final double gap;

  /// Below this a tile stops being able to hold a code, a rate and a move.
  static const double _minTileWidth = 132;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth =
            (constraints.maxWidth - gap * (rates.length - 1)) / rates.length;
        if (tileWidth < _minTileWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < rates.length; index += 1) ...[
                if (index > 0) SizedBox(height: gap),
                _RateRow(
                  rate: rates[index],
                  trend: trendFor(rates[index].fromCode),
                ),
              ],
            ],
          );
        }
        // IntrinsicHeight, not a bare stretched Row: the dashboard body is a
        // scroll view, so vertical constraints here are unbounded and
        // CrossAxisAlignment.stretch on its own would assert. Tiles still have
        // to match — one currency without a sparkline must not leave a shorter
        // tile beside the others.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < rates.length; index += 1) ...[
                if (index > 0) SizedBox(width: gap),
                Expanded(
                  child: _RateTile(
                    rate: rates[index],
                    trend: trendFor(rates[index].fromCode),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The narrow form: identity and age at the start, the trend running through
/// the middle, the rate and its move at the end.
class _RateRow extends StatelessWidget {
  const _RateRow({required this.rate, required this.trend});

  final ResolvedRate rate;
  final List<double> trend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final change = _changePercent(trend);
    final tone = _toneFor(context, change);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.sm,
          vertical: spacing.sm,
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ltrIsolated(rate.fromCode),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.mutedInk,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
                Text(
                  _ageLabel(l10n, rate),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: rate.isStale ? colors.warning : colors.mutedInk,
                  ),
                ),
              ],
            ),
            SizedBox(width: spacing.sm),
            if (trend.length >= 3)
              Expanded(
                child: SizedBox(
                  height: 26,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _SparklinePainter(points: trend, color: tone),
                  ),
                ),
              )
            else
              const Spacer(),
            SizedBox(width: spacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatRateQuote(rate.rate, rate.toCode),
                  style: switch (theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.ink,
                  )) {
                    final style? => PointyTypography.numeric(style),
                    null => null,
                  },
                ),
                if (change != null) _ChangePill(change: change, tone: tone),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// How the shop settles, and whether any rate on show is past its shelf life.
class _HeaderPills extends StatelessWidget {
  const _HeaderPills({required this.rates, this.onOpenRates});

  final CurrentRates rates;
  final VoidCallback? onOpenRates;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rates.hasStaleRates) ...[
          PointyStatusPill(
            label: l10n.exchangeRateStaleBadge,
            icon: Icons.schedule,
            color: colors.warning,
          ),
          SizedBox(width: spacing.xs),
        ],
        PointyStatusPill(
          label: _instrumentLabel(l10n, rates.instrument),
          icon: rates.instrument == SettlementInstrument.bank
              ? Icons.account_balance_outlined
              : Icons.payments_outlined,
          color: colors.mutedInk,
        ),
        if (onOpenRates != null)
          IconButton(
            tooltip: l10n.dashboardExchangeRatesOpenAction,
            onPressed: onOpenRates,
            icon: const Icon(Icons.open_in_new),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

/// One currency: the code, the rate, which way it moved, and how old it is.
class _RateTile extends StatelessWidget {
  const _RateTile({required this.rate, required this.trend});

  final ResolvedRate rate;

  /// Recent rates, oldest first. Empty when the history has not landed or the
  /// series is too thin to say anything — the tile is complete without it.
  final List<double> trend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final change = _changePercent(trend);
    final tone = _toneFor(context, change);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.sm,
          vertical: spacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    // The ISO code, not the symbol: it is the identity the feed
                    // speaks, it needs no currency registry to render, and it
                    // is what every rate board in the country prints.
                    ltrIsolated(rate.fromCode),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.mutedInk,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                if (change != null) _ChangePill(change: change, tone: tone),
              ],
            ),
            SizedBox(height: spacing.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                formatRateQuote(rate.rate, rate.toCode),
                maxLines: 1,
                style: switch (theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.ink,
                )) {
                  final style? => PointyTypography.numeric(style),
                  null => null,
                },
              ),
            ),
            if (trend.length >= 3) ...[
              SizedBox(height: spacing.xs),
              SizedBox(
                height: 22,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _SparklinePainter(points: trend, color: tone),
                ),
              ),
            ],
            SizedBox(height: spacing.xs),
            Text(
              _ageLabel(l10n, rate),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: rate.isStale ? colors.warning : colors.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The move since the previous published rate.
///
/// Coloured by what it costs the shop, not by the direction of the line: a
/// dinar that buys fewer dollars makes the next container dearer, so a rise is
/// the amber one. Reading "up" as good here would be importing a stock-market
/// convention into a currency the shop only ever *spends*.
class _ChangePill extends StatelessWidget {
  const _ChangePill({required this.change, required this.tone});

  final double change;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = change > 0
        ? Icons.arrow_drop_up
        : change < 0
        ? Icons.arrow_drop_down
        : Icons.remove;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(PointyRadii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: tone),
            Text(
              ltrIsolated('${change.abs().toStringAsFixed(2)}%'),
              style: switch (theme.textTheme.labelSmall?.copyWith(
                color: tone,
                fontWeight: FontWeight.w700,
              )) {
                final style? => PointyTypography.numeric(style),
                null => null,
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A bare trend line: no axes, no grid, no labels. It answers "which way" and
/// deliberately not "by how much" — the pill beside it already says that.
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({required this.points, required this.color});

  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || size.width <= 0 || size.height <= 0) {
      return;
    }
    var low = points.first;
    var high = points.first;
    for (final point in points) {
      low = point < low ? point : low;
      high = point > high ? point : high;
    }
    // A flat series would divide by zero; draw it down the middle instead.
    final span = high - low;
    final stride = size.width / (points.length - 1);
    const inset = 2.0;
    final usable = size.height - inset * 2;

    final path = Path();
    for (var index = 0; index < points.length; index += 1) {
      final ratio = span == 0 ? 0.5 : (points[index] - low) / span;
      final offset = Offset(stride * index, inset + usable - (usable * ratio));
      if (index == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.points, points);
}

String _instrumentLabel(AppLocalizations l10n, SettlementInstrument value) {
  return value == SettlementInstrument.bank
      ? l10n.settlementInstrumentBank
      : l10n.settlementInstrumentCash;
}

String _ageLabel(AppLocalizations l10n, ResolvedRate rate) {
  return rate.ageHours >= 48
      ? l10n.exchangeRateAgeDays((rate.ageHours / 24).round())
      : l10n.exchangeRateAgeHours(rate.ageHours.round());
}

/// The move across the window the sparkline draws, or null when there is no
/// earlier rate to compare against.
///
/// Deliberately the whole window rather than the last hop between two
/// publications: the line beside it spans several days, and a badge reading
/// +0.02% under a line that climbs the height of the tile is a badge nobody
/// believes. What the owner is asking is "where has the dollar gone this week",
/// and this is that number.
double? _changePercent(List<double> trend) {
  if (trend.length < 2) {
    return null;
  }
  final first = trend.first;
  if (first <= 0) {
    return null;
  }
  return ((trend.last - first) / first) * 100;
}

Color _toneFor(BuildContext context, double? change) {
  final colors = context.pointyColors;
  if (change == null || change == 0) {
    return colors.mutedInk;
  }
  return change > 0 ? colors.warning : colors.success;
}
