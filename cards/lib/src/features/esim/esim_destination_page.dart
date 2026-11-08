import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/result.dart';
import '../../data/models/esim.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/empty_state.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/pressable.dart';
import '../../shared/relay_error_text.dart';
import '../../shared/side_back.dart';
import '../../shared/skeleton.dart';
import '../../shared/esim_card_art.dart';
import 'esim_format.dart';
import 'esim_plan_sheet.dart';
import 'esim_split.dart';
import 'esim_support_banner.dart';

/// One destination: its plans, smallest first, and where they work.
class EsimDestinationPage extends StatefulWidget {
  const EsimDestinationPage({
    super.key,
    required this.destination,
    this.name = '',
  });

  final String destination;

  /// Shown until the page's own answer comes.
  final String name;

  static Future<void> open(
    BuildContext context,
    String key, {
    String name = '',
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: screenSettings('esim_destination'),
      builder: (_) => EsimDestinationPage(destination: key, name: name),
    ),
  );

  @override
  State<EsimDestinationPage> createState() => _EsimDestinationPageState();
}

class _EsimDestinationPageState extends State<EsimDestinationPage> {
  EsimDestination? _destination;
  Object? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      CardsScope.of(context).esimCompatibility.load();
      _load();
    }
  }

  Future<void> _load() async {
    final result = await CardsScope.of(context).esim
        .destination(widget.destination);
    if (!mounted) {
      return;
    }
    setState(() {
      switch (result) {
        case Ok(:final value):
          _destination = value;
          _error = null;
        case Error(:final exception):
          _error = exception;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final destination = _destination;
    return SideBack(
      child: Scaffold(
        appBar: AppBar(
          title: Text(destination?.name ?? widget.name),
          automaticallyImplyLeading: !SideBack.active(context),
        ),
        body: Builder(
          // Its own context: under SideBack, where the side column is
          // already off the width.
          builder: (context) {
            final padding = CardsLayout.page(
              context,
              top: CardsSpace.sm,
              bottom: MediaQuery.paddingOf(context).bottom + CardsSpace.xl,
            );
            if (destination == null) {
              return _error != null
                  ? EmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: l10n.esimLoadFailed,
                      body: relayErrorText(l10n, _error!),
                      actionLabel: l10n.esimTryAgain,
                      onAction: _load,
                    )
                  : ListView(
                      padding: padding,
                      children: [
                        for (var i = 0; i < 5; i++)
                          const Padding(
                            padding: EdgeInsets.only(bottom: CardsSpace.md),
                            child: Skeleton(
                              height: 92,
                              radius: CardsRadii.card,
                            ),
                          ),
                      ],
                    );
            }
            final wide = EsimSplit.of(context);
            final hero = EsimHero(
              name: destination.name,
              country: destination.country,
              height: wide ? 220 : 148,
            );
            final plans = [
              for (final plan in destination.plans)
                Padding(
                  padding: const EdgeInsets.only(bottom: CardsSpace.md),
                  child: _PlanCard(
                    plan: plan,
                    showOperator:
                        destination.plans
                            .map((p) => p.operator)
                            .toSet()
                            .length >
                        1,
                    onTap: () {
                      Haptics.tap();
                      showEsimPlanSheet(
                        context,
                        destination: destination,
                        plan: plan,
                      );
                    },
                  ),
                ),
              if (destination.countries.isNotEmpty)
                _Coverage(destination: destination),
            ];
            if (wide) {
              return EsimSplit(
                start: Builder(
                  builder: (context) => ListView(
                    padding: CardsLayout.page(context, top: CardsSpace.sm),
                    children: [
                      hero,
                      const SizedBox(height: CardsSpace.lg),
                      const EsimSupportBanner(),
                    ],
                  ),
                ),
                end: ListView(
                  padding: EdgeInsets.fromLTRB(
                    CardsSpace.gutter,
                    CardsSpace.sm,
                    CardsSpace.gutter,
                    MediaQuery.paddingOf(context).bottom + CardsSpace.xl,
                  ),
                  children: plans,
                ),
              );
            }
            return ListView(
              padding: padding,
              children: [
                hero,
                const SizedBox(height: CardsSpace.lg),
                const EsimSupportBanner(),
                ...plans,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.onTap,
    required this.showOperator,
  });

  final EsimPlan plan;

  /// Two networks sell the same plan here: say whose this is.
  final bool showOperator;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(CardsSpace.lg),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(CardsRadii.card),
          boxShadow: CardsShadows.raised,
          border: Border.all(
            color: scheme.outline.withValues(alpha: 0.6),
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: plan.unlimited
                        ? Text(
                            l10n.esimUnlimited,
                            style: theme.textTheme.titleLarge,
                          )
                        : EsimLtr(plan.data, style: theme.textTheme.titleLarge),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.esimValidDays(plan.days),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (showOperator && plan.operator.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: EsimLtr(
                        plan.operator,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (plan.voice > 0 || plan.text > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      l10n.esimVoiceAndText(plan.voice, plan.text),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              formatMoney(l10n, plan.price),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(width: CardsSpace.xs),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Where it works: one country's networks, or a region's countries.
class _Coverage extends StatelessWidget {
  const _Coverage({required this.destination});

  final EsimDestination destination;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final countries = destination.countries;
    final text = countries.length == 1
        ? countries.first.networks.join('، ')
        : [for (final c in countries) c.name].join('، ');
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: CardsSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            countries.length == 1
                ? l10n.esimNetworks
                : l10n.esimCountriesCount(countries.length),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: CardsSpace.xs),
          Text(text, style: muted),
        ],
      ),
    );
  }
}
