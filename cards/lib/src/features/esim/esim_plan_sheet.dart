import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/esim/esim_device.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/esim_card_art.dart';
import 'esim_checkout.dart';
import 'esim_format.dart';
import 'esim_share.dart';
import '../links/cards_link.dart';

/// Who the eSIM is for.
enum EsimRecipient { me, someoneElse }

/// A plan up close, before paying: what is in it, who it is for, and what to
/// check first. Then the ordinary checkout.
Future<void> showEsimPlanSheet(
  BuildContext context, {
  required EsimDestination destination,
  required EsimPlan plan,
}) => showModalBottomSheet<void>(
  context: context,
  routeSettings: screenSettings('esim_plan'),
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => EsimPlanSheet(destination: destination, plan: plan),
);

class EsimPlanSheet extends StatefulWidget {
  const EsimPlanSheet({
    super.key,
    required this.destination,
    required this.plan,
  });

  final EsimDestination destination;
  final EsimPlan plan;

  @override
  State<EsimPlanSheet> createState() => _EsimPlanSheetState();
}

class _EsimPlanSheetState extends State<EsimPlanSheet> {
  final _label = TextEditingController();
  EsimRecipient? _recipient;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      CardsScope.of(context).esimCompatibility.load();
    }
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  /// A phone that looks unable to take an eSIM starts on «لشخص آخر»; the choice
  /// stays the customer's.
  EsimRecipient _chosen(EsimSupport support) =>
      _recipient ??
      (support == EsimSupport.no
          ? EsimRecipient.someoneElse
          : EsimRecipient.me);

  Future<void> _buy(EsimRecipient recipient) async {
    Haptics.tap();
    final navigator = Navigator.of(context);
    final parent = navigator.context;
    final label = _label.text.trim();
    final account = recipient == EsimRecipient.someoneElse
        ? {'gift': '1', if (label.isNotEmpty) 'label': label}
        : const <String, String>{};
    navigator.pop();
    await checkoutEsimPlan(
      parent,
      destinationName: widget.destination.name,
      plan: widget.plan,
      country: widget.destination.country,
      orderAccount: account,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final plan = widget.plan;
    final compatibility = CardsScope.of(context).esimCompatibility;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ValueListenableBuilder(
      valueListenable: compatibility.support,
      builder: (context, support, _) {
        final recipient = _chosen(support);
        // The button stays in reach, however long a plan's notes are.
        final button = Padding(
          padding: EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.md,
            CardsSpace.gutter,
            MediaQuery.viewInsetsOf(context).bottom + CardsSpace.lg,
          ),
          child: Row(
            children: [
              // This plan's own link: a friend opens the app on it.
              Builder(
                builder: (context) => IconButton.outlined(
                  tooltip: l10n.shareAction,
                  constraints: const BoxConstraints.tightFor(
                    width: CardsSizes.button,
                    height: CardsSizes.button,
                  ),
                  icon: const Icon(CupertinoIcons.share, size: 20),
                  onPressed: () => shareEsimLink(
                    context,
                    EsimShelfLink(
                      destination: widget.destination.key,
                      plan: plan.id,
                    ),
                    title:
                        '${widget.destination.name} · ${esimPlanText(l10n, data: plan.data, days: plan.days, unlimited: plan.unlimited)}',
                  ),
                ),
              ),
              const SizedBox(width: CardsSpace.sm),
              Expanded(
                child: FilledButton(
                  onPressed: () => _buy(recipient),
                  child: Text(l10n.esimBuyFor(formatMoney(l10n, plan.price))),
                ),
              ),
            ],
          ),
        );
        final body = SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.lg,
            CardsSpace.gutter,
            CardsSpace.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EsimHero(
                name: widget.destination.name,
                country: widget.destination.country,
                height: 132,
                caption: esimPlanText(
                  l10n,
                  data: plan.data,
                  days: plan.days,
                  unlimited: plan.unlimited,
                ),
              ),
              if (plan.promo case final promo?) ...[
                const SizedBox(height: CardsSpace.md),
                // Side by side; one under the other at the largest text.
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: CardsSpace.md,
                  runSpacing: CardsSpace.xs,
                  children: [
                    Pill(
                      text: esimPromoLabel(l10n, promo),
                      tone: PillTone.promo,
                      icon: Icons.local_offer_rounded,
                    ),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (plan.regularPrice case final regular?)
                            TextSpan(
                              text: '${formatMoney(l10n, regular)}  ',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                          TextSpan(text: formatMoney(l10n, plan.price)),
                        ],
                      ),
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: CardsSpace.lg),
              Grouped(
                children: [
                  _Fact(
                    label: l10n.esimFactData,
                    value: plan.unlimited ? l10n.esimUnlimited : plan.data,
                    ltr: !plan.unlimited,
                  ),
                  _Fact(
                    label: l10n.esimFactValidity,
                    value: l10n.esimValidDays(plan.days),
                  ),
                  if (plan.operator.isNotEmpty)
                    _Fact(
                      label: l10n.esimFactNetwork,
                      value: plan.operator,
                      ltr: true,
                    ),
                  _Fact(
                    label: l10n.esimFactTopUp,
                    value: plan.rechargeable
                        ? l10n.esimTopUpYes
                        : l10n.esimTopUpNo,
                  ),
                ],
              ),
              const SizedBox(height: CardsSpace.lg),
              if (plan.startsOnFirstUse) ...[
                EsimNote(
                  icon: Icons.schedule_rounded,
                  text: l10n.esimStartsOnFirstUse,
                ),
                const SizedBox(height: CardsSpace.sm),
              ],
              if (plan.installWindowDays > 0) ...[
                EsimNote(
                  icon: Icons.event_available_rounded,
                  text: l10n.esimInstallWithin(plan.installWindowDays),
                ),
                const SizedBox(height: CardsSpace.sm),
              ],
              EsimNote(
                icon: Icons.lock_open_rounded,
                text: l10n.esimUnlockedNote,
              ),
              if (plan.voice == 0 && plan.text == 0) ...[
                const SizedBox(height: CardsSpace.sm),
                EsimNote(
                  icon: Icons.phone_disabled_rounded,
                  text: l10n.esimDataOnlyNote,
                ),
              ],
              if (plan.otherInfo.trim().isNotEmpty) ...[
                const SizedBox(height: CardsSpace.sm),
                EsimNote(
                  icon: Icons.info_outline_rounded,
                  text: plan.otherInfo.trim(),
                ),
              ],
              const SizedBox(height: CardsSpace.xl),
              Text(l10n.esimWhoFor, style: theme.textTheme.titleSmall),
              const SizedBox(height: CardsSpace.sm),
              SegmentedPill<EsimRecipient>(
                segments: [
                  (EsimRecipient.me, l10n.esimForMe),
                  (EsimRecipient.someoneElse, l10n.esimForSomeoneElse),
                ],
                selected: recipient,
                onChanged: (value) {
                  Haptics.select();
                  setState(() => _recipient = value);
                },
              ),
              const SizedBox(height: CardsSpace.md),
              if (recipient == EsimRecipient.someoneElse) ...[
                TextField(
                  controller: _label,
                  maxLength: 60,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: l10n.esimRecipientName,
                    counterText: '',
                  ),
                ),
                const SizedBox(height: CardsSpace.sm),
                Text(l10n.esimForSomeoneElseNote, style: muted),
              ] else if (support == EsimSupport.no) ...[
                EsimNote(
                  icon: Icons.warning_amber_rounded,
                  color: theme.colorScheme.error,
                  text: l10n.esimForMeUnsupportedNote,
                ),
              ],
            ],
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(child: body),
            button,
          ],
        );
      },
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.ltr = false});

  final String label;
  final String value;
  final bool ltr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.lg,
        vertical: CardsSpace.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Flexible(
            child: ltr
                ? EsimLtr(
                    value,
                    style: style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}
