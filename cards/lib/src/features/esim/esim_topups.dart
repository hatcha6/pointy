import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/result.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/section_header.dart';
import '../../shared/skeleton.dart';
import 'esim_checkout.dart';
import 'esim_destination_page.dart';
import 'esim_format.dart';

/// The top-ups, over the eSIM's page.
Future<void> showEsimTopUpSheet(BuildContext context, CustomerEsim esim) =>
    showModalBottomSheet<void>(
      context: context,
      routeSettings: screenSettings('esim_topups'),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          CardsSpace.lg,
          CardsSpace.gutter,
          CardsSpace.xl,
        ),
        child: EsimTopUps(esim: esim),
      ),
    );

/// What this eSIM can be topped up with, one tap from the checkout. A plan that
/// takes no top-ups offers a new eSIM instead.
class EsimTopUps extends StatefulWidget {
  const EsimTopUps({super.key, required this.esim, this.onRead});

  final CustomerEsim esim;
  final VoidCallback? onRead;

  @override
  State<EsimTopUps> createState() => _EsimTopUpsState();
}

class _EsimTopUpsState extends State<EsimTopUps> {
  List<EsimPlan>? _plans;
  bool _failed = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final result = await CardsScope.of(context).esim.topUps(widget.esim.iccid);
    if (!mounted) {
      return;
    }
    setState(() {
      switch (result) {
        case Ok(:final value):
          _plans = value;
          _failed = false;
        case Error():
          _failed = true;
      }
    });
  }

  Future<void> _buy(EsimPlan plan) async {
    Haptics.tap();
    // The sheet leaves first; the page under it carries the checkout.
    final navigator = Navigator.of(context);
    final parent = navigator.context;
    navigator.pop();
    await checkoutEsimPlan(
      parent,
      destinationName: widget.esim.destinationName,
      country: widget.esim.country,
      plan: plan,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final plans = _plans;
    final header = SectionHeader(
      title: l10n.esimTopUpTitle,
      padding: const EdgeInsets.only(bottom: CardsSpace.sm),
    );
    if (plans == null) {
      if (_failed) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            TextButton(onPressed: _load, child: Text(l10n.esimTryAgain)),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Skeleton(height: 120, radius: CardsRadii.card),
        ],
      );
    }
    if (plans.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Text(l10n.esimNoTopUps, style: theme.textTheme.bodyMedium),
          const SizedBox(height: CardsSpace.sm),
          OutlinedButton(
            onPressed: () => EsimDestinationPage.open(
              context,
              widget.esim.destination,
              name: widget.esim.destinationName,
            ),
            child: Text(l10n.esimBuyAnother),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Grouped(
          children: [
            for (final plan in plans)
              ListTile(
                title: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: plan.unlimited
                      ? Text(l10n.esimUnlimited)
                      : EsimLtr(plan.data, style: theme.textTheme.titleSmall),
                ),
                subtitle: Text(l10n.esimValidDays(plan.days)),
                trailing: Text(
                  formatMoney(l10n, plan.price),
                  style: theme.textTheme.titleSmall,
                ),
                onTap: () => _buy(plan),
              ),
          ],
        ),
      ],
    );
  }
}
