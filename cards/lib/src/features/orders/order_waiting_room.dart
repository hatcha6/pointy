import 'package:flutter/material.dart';

import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/container_route.dart';
import '../../shared/motion.dart';
import '../runner/runner_bar.dart';
import '../runner/runner_game.dart';

/// A late order's page once the wait runs long: the card small at the top
/// with a line on where things stand, and a game to pass the time under
/// it. The order still turns into the card the moment it lands.
class OrderWaitingRoom extends StatelessWidget {
  const OrderWaitingRoom({
    super.key,
    required this.gameKey,
    required this.title,
    this.body,
    required this.orderReady,
    required this.onShowOrder,
    this.brand,
    this.detail,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.onRunEnded,
  });

  /// The game's state, which the page asks whether a run is under way.
  final GlobalKey<RunnerGameState> gameKey;
  final CardBrand? brand;
  final String title;

  /// What to do meanwhile, once the wait is long enough to say so.
  final String? body;

  /// Under the sentence: what the order is about (a top-up's account).
  final Widget? detail;

  final bool orderReady;
  final VoidCallback onShowOrder;
  final RunnerRunEnded? onRunEnded;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dependencies = CardsScope.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (brand != null) ...[
              SizedBox(
                width: 84,
                child: ContainerLanding(
                  same: true,
                  radius: CardsRadii.art,
                  child: CardArt(brand: brand!, radius: CardsRadii.art),
                ),
              ),
              const SizedBox(width: CardsSpace.lg),
            ],
            Expanded(
              // The words change when the wait turns long; the game below
              // them does not move.
              child: CardsSwitcher(
                alignment: AlignmentDirectional.centerStart,
                child: Column(
                  key: ValueKey('$title$body'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (body != null) ...[
                      const SizedBox(height: CardsSpace.xs),
                      Text(
                        body!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
        if (detail != null) ...[const SizedBox(height: CardsSpace.md), detail!],
        const SizedBox(height: CardsSpace.lg),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CardsRadii.card),
            boxShadow: CardsShadows.art,
          ),
          child: RunnerGame(
            key: gameKey,
            records: dependencies.runnerRecords,
            audio: dependencies.runnerAudio,
            board: dependencies.runnerBoard,
            reveal: true,
            orderReady: orderReady,
            onShowOrder: onShowOrder,
            onRunEnded: onRunEnded,
          ),
        ),
        RunnerBar(
          records: dependencies.runnerRecords,
          board: dependencies.runnerBoard,
        ),
        if (primaryLabel != null) ...[
          const SizedBox(height: CardsSpace.sm),
          FilledButton(onPressed: onPrimary, child: Text(primaryLabel!)),
        ],
        if (secondaryLabel != null) ...[
          const SizedBox(height: CardsSpace.xs),
          TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
        ],
      ],
    );
  }
}
