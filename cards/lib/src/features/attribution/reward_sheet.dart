import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../data/models/campaign.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';

/// «أُضيف 5 د.ل إلى رصيدك»: a campaign's credit has landed, and why — the
/// code typed, the flyer scanned, the creator followed.
Future<void> showRewardSheet(BuildContext context, CampaignReward reward) {
  Haptics.success();
  return showModalBottomSheet<void>(
    context: context,
    routeSettings: screenSettings('campaign_reward'),
    useSafeArea: true,
    // As tall as it needs, and it scrolls past that: at a large text size it
    // is more than the default sheet's share of the screen.
    isScrollControlled: true,
    builder: (_) => RewardSheet(reward: reward),
  );
}

/// Shows each reward [AttributionRepository] receives, over whatever screen
/// is up, once.
class RewardListener extends StatefulWidget {
  const RewardListener({super.key, required this.child});

  final Widget child;

  @override
  State<RewardListener> createState() => _RewardListenerState();
}

class _RewardListenerState extends State<RewardListener> {
  ValueNotifier<CampaignReward?>? _reward;
  bool _showing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reward = CardsScope.of(context).attribution.reward;
    if (reward != _reward) {
      _reward?.removeListener(_changed);
      _reward = reward..addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    _reward?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final reward = _reward?.value;
    if (reward == null ||
        _showing ||
        CardsScope.of(context).attribution.holding) {
      return;
    }
    _showing = true;
    // After the frame: a sign-in sheet may still be closing.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      CardsScope.of(context).attribution.rewardShown();
      await showRewardSheet(context, reward);
      _showing = false;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class RewardSheet extends StatelessWidget {
  const RewardSheet({super.key, required this.reward});

  final CampaignReward reward;

  /// Why, in the words of how the customer came.
  static String because(AppLocalizations l10n, CampaignReward reward) {
    final name = reward.displayName.trim();
    return switch (reward.kind) {
      'creator' =>
        name.isEmpty
            ? l10n.rewardBecauseCreatorUnnamed
            : l10n.rewardBecauseCreator(name),
      'referral' =>
        name.isEmpty
            ? l10n.rewardBecauseInviteUnnamed
            : l10n.rewardBecauseInvite(name),
      'flyer' || 'billboard' when reward.followed =>
        name.isNotEmpty
            ? l10n.rewardBecauseFlyer(name)
            : reward.kind == 'flyer'
            ? l10n.rewardBecauseFlyerUnnamed
            : l10n.rewardBecauseBillboardUnnamed,
      'ad' when reward.followed => l10n.rewardBecauseAd,
      _ => l10n.rewardBecauseCode(reward.code),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        CardsSpace.gutter,
        CardsSpace.lg,
        CardsSpace.gutter,
        CardsSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(
                begin: MediaQuery.disableAnimationsOf(context) ? 1 : 0.6,
                end: 1,
              ),
              duration: CardsMotion.emphasized,
              curve: Curves.elasticOut,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                  boxShadow: CardsShadows.raised,
                ),
                child: Icon(
                  Icons.redeem_rounded,
                  size: 48,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(height: CardsSpace.xl),
          Text(
            l10n.rewardTitle(formatMoney(l10n, reward.amount)),
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: CardsSpace.sm),
          Text(
            because(l10n, reward),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: CardsSpace.xs),
          Text(
            l10n.rewardBody,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: CardsSpace.xl),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.rewardAction),
          ),
        ],
      ),
    );
  }
}
