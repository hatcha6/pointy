import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/result.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import 'runner_board.dart';

/// The shared leaderboard for one period: the top runs under their aliases,
/// the customer's own row marked, and their place below when they are not
/// in the top. It draws what the sheet already holds ([result], null while
/// it loads), so switching between periods never flashes a spinner.
class RunnerBoardList extends StatelessWidget {
  const RunnerBoardList({
    super.key,
    required this.result,
    required this.onRetry,
  });

  final Result<RunnerBoard>? result;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    switch (result) {
      case null:
        return const Padding(
          padding: EdgeInsets.all(CardsSpace.xl),
          child: Center(child: CircularProgressIndicator()),
        );
      case Error():
        return Column(
          children: [
            const SizedBox(height: CardsSpace.lg),
            Text(l10n.runnerBoardFailed, style: quiet),
            TextButton(onPressed: onRetry, child: Text(l10n.tryAgain)),
          ],
        );
      case Ok(value: final board) when board.entries.isEmpty:
        return Padding(
          padding: const EdgeInsets.all(CardsSpace.lg),
          child: Text(
            l10n.runnerBoardEmpty,
            textAlign: TextAlign.center,
            style: quiet,
          ),
        );
      case Ok(value: final board):
        final me = board.me;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Grouped(
              children: [for (final entry in board.entries) _Row(entry: entry)],
            ),
            if (me != null && !board.meShown) ...[
              const SizedBox(height: CardsSpace.sm),
              Grouped(children: [_Row(entry: me)]),
            ],
            const SizedBox(height: CardsSpace.sm),
            Text(
              l10n.runnerBoardNames,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry});

  final RunnerBoardEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final medal = switch (entry.rank) {
      1 => const Color(0xFFFFC83D),
      2 => const Color(0xFFB8C2CC),
      3 => const Color(0xFFD9915A),
      _ => null,
    };
    return Container(
      color: entry.me
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : null,
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.lg,
        vertical: CardsSpace.md,
      ),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 28),
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: medal ?? theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(CardsRadii.pill),
            ),
            child: Text(
              '${entry.rank}',
              textDirection: TextDirection.ltr,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: medal == null ? null : const Color(0xFF2A2A2A),
              ),
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Flexible(
            fit: FlexFit.tight,
            child: Text(
              entry.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: entry.me ? FontWeight.w700 : null,
              ),
            ),
          ),
          if (entry.me) ...[
            const SizedBox(width: CardsSpace.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(CardsRadii.pill),
              ),
              child: Text(
                l10n.runnerYou,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          const SizedBox(width: CardsSpace.md),
          Text(
            '${entry.score}',
            textDirection: TextDirection.ltr,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
