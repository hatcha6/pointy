import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import 'runner_board.dart';
import 'runner_board_list.dart';
import '../../core/result.dart';
import '../../shared/motion.dart';
import 'runner_records.dart';
import 'runner_sprites.dart';

/// «أفضل نتائجك»: the best runs on this phone, the shared leaderboard
/// (this week and all time), and the runners a score unlocks.
Future<void> showRunnerScores(
  BuildContext context,
  RunnerRecords records, {
  RunnerBoardRepository? board,
}) => showModalBottomSheet<void>(
  context: context,
  routeSettings: screenSettings('runner_scores'),
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => RunnerScoresSheet(records: records, board: board),
);

enum _Tab { mine, week, all }

class RunnerScoresSheet extends StatefulWidget {
  const RunnerScoresSheet({super.key, required this.records, this.board});

  final RunnerRecords records;

  /// The shared leaderboard; without it only this phone's runs show.
  final RunnerBoardRepository? board;

  @override
  State<RunnerScoresSheet> createState() => _RunnerScoresSheetState();
}

class _RunnerScoresSheetState extends State<RunnerScoresSheet> {
  // The week's board first: a fresh one gives a newcomer a real chance.
  late _Tab _tab = widget.board == null ? _Tab.mine : _Tab.week;

  RunnerRecords get records => widget.records;

  /// Both boards, read once as the sheet opens and kept while it is up:
  /// a tab shows at once, never a spinner between them.
  final Map<RunnerPeriod, Result<RunnerBoard>?> _boards = {};

  @override
  void initState() {
    super.initState();
    for (final period in RunnerPeriod.values) {
      _load(period);
    }
  }

  Future<void> _load(RunnerPeriod period) async {
    final board = widget.board;
    if (board == null) {
      return;
    }
    if (_boards[period] != null) {
      setState(() => _boards[period] = null);
    }
    final result = await board.board(period);
    if (mounted) {
      setState(() => _boards[period] = result);
    }
  }

  RunnerPeriod get _period =>
      _tab == _Tab.all ? RunnerPeriod.all : RunnerPeriod.week;

  /// This phone's own best runs.
  Widget _mine(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (records.top.isEmpty) {
      return Text(
        l10n.runnerNoRuns,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Grouped(
      children: [
        for (final (i, run) in records.top.indexed)
          _RunRow(place: i + 1, run: run),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: records,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          0,
          CardsSpace.gutter,
          CardsSpace.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.runnerScoresTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: CardsSpace.lg),
            Row(
              children: [
                _Stat(label: l10n.runnerStatBest, value: records.best),
                _Stat(label: l10n.runnerStatRuns, value: records.played),
                _Stat(label: l10n.runnerStatCoins, value: records.coins),
              ],
            ),
            const SizedBox(height: CardsSpace.xl),
            Grouped(
              title: l10n.runnerCharacters,
              children: [_Characters(records: records)],
            ),
            const SizedBox(height: CardsSpace.xl),
            if (widget.board != null) ...[
              SegmentedButton<_Tab>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: _Tab.week,
                    label: Text(l10n.runnerTabWeek),
                  ),
                  ButtonSegment(
                    value: _Tab.all,
                    label: Text(l10n.runnerTabAll),
                  ),
                  ButtonSegment(
                    value: _Tab.mine,
                    label: Text(l10n.runnerTabMine),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (tabs) {
                  Haptics.select();
                  setState(() => _tab = tabs.first);
                },
              ),
              const SizedBox(height: CardsSpace.lg),
            ],
            // Tabs fade into one another and the sheet eases to the new
            // height, instead of jumping.
            AnimatedSize(
              duration: CardsMotion.standard,
              curve: CardsMotion.curve,
              alignment: Alignment.topCenter,
              child: CardsSwitcher(
                alignment: Alignment.topCenter,
                child: KeyedSubtree(
                  key: ValueKey(_tab),
                  child: switch (_tab) {
                    _Tab.mine => _mine(context),
                    _Tab.week || _Tab.all => RunnerBoardList(
                      result: _boards[_period],
                      onRetry: () => _load(_period),
                    ),
                  },
                ),
              ),
            ),
            const SizedBox(height: CardsSpace.lg),
            Text(
              l10n.runnerCredit,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            textDirection: TextDirection.ltr,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.place, required this.run});

  final int place;
  final RunnerRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final medal = switch (place) {
      1 => const Color(0xFFFFC83D),
      2 => const Color(0xFFB8C2CC),
      3 => const Color(0xFFD9915A),
      _ => null,
    };
    final date = MaterialLocalizations.of(context).formatShortDate(run.at);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.lg,
        vertical: CardsSpace.md,
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: medal ?? theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$place',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: medal == null ? null : const Color(0xFF2A2A2A),
              ),
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Text(
              date,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (run.coins > 0) ...[
            Image.asset('assets/runner/hud_coin.png', width: 16, height: 16),
            const SizedBox(width: 2),
            Text(
              '${run.coins}',
              textDirection: TextDirection.ltr,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(width: CardsSpace.md),
          ],
          Text(
            '${run.score}',
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

/// The five runners: tap one to run as it, locked ones say what unlocks
/// them.
class _Characters extends StatelessWidget {
  const _Characters({required this.records});

  final RunnerRecords records;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CardsSpace.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final character in RunnerCharacter.values)
            () {
              final open = records.unlocked(character);
              final chosen = records.character == character;
              // An equal share of the row each, however many digits the
              // unlock score under a locked one has.
              return Expanded(
                child: Semantics(
                  button: open,
                  selected: chosen,
                  child: GestureDetector(
                    onTap: open
                        ? () {
                            Haptics.select();
                            records.character = character;
                          }
                        : null,
                    child: Column(
                      children: [
                        AnimatedContainer(
                          duration: CardsMotion.fast,
                          width: 52,
                          height: 52,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.surfaceContainerHighest,
                            border: Border.all(
                              width: 2.5,
                              color: chosen
                                  ? theme.colorScheme.primary
                                  : Colors.transparent,
                            ),
                          ),
                          child: Opacity(
                            opacity: open ? 1 : 0.35,
                            child: Image.asset(
                              'assets/runner/${character.name}_idle.png',
                            ),
                          ),
                        ),
                        const SizedBox(height: CardsSpace.xs),
                        SizedBox(
                          height: 16,
                          child: open
                              ? null
                              : FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.lock_rounded,
                                        size: 12,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                      Text(
                                        l10n.runnerUnlockAt(
                                          '${character.unlock}',
                                        ),
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }(),
        ],
      ),
    );
  }
}
