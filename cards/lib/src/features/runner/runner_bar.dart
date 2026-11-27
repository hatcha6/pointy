import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import '../../shared/haptics.dart';
import 'runner_board.dart';
import 'runner_records.dart';
import 'runner_scores_sheet.dart';

/// Under the game: the score to beat, the scores, and the sound.
class RunnerBar extends StatelessWidget {
  const RunnerBar({super.key, required this.records, this.board});

  final RunnerRecords records;
  final RunnerBoardRepository? board;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: records,
      builder: (context, _) => Row(
        children: [
          const SizedBox(width: CardsSpace.xs),
          const Icon(
            Icons.emoji_events_rounded,
            size: 20,
            color: Color(0xFFE8A70C),
          ),
          const SizedBox(width: CardsSpace.xs),
          Expanded(
            child: Text(
              l10n.runnerBest('${records.best}'),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.runnerScoresTitle,
            onPressed: () {
              Haptics.select();
              showRunnerScores(context, records, board: board);
            },
            icon: const Icon(Icons.leaderboard_rounded),
          ),
          IconButton(
            tooltip: records.muted ? l10n.runnerSoundOn : l10n.runnerSoundOff,
            onPressed: () {
              Haptics.select();
              records.muted = !records.muted;
            },
            icon: Icon(
              records.muted
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
            ),
          ),
        ],
      ),
    );
  }
}
