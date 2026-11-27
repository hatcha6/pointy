import '../../core/result.dart';
import '../../data/api/relay_api.dart';
import 'runner_records.dart';

/// A leaderboard's period: this Libyan week, or all time.
enum RunnerPeriod { week, all }

/// One row of the leaderboard. [name] is the relay's alias for the player
/// (an animal and a trait), never anything they typed or their number.
class RunnerBoardEntry {
  const RunnerBoardEntry({
    required this.rank,
    required this.name,
    required this.score,
    this.me = false,
  });

  factory RunnerBoardEntry.fromJson(Map<String, dynamic> json, {bool? me}) =>
      RunnerBoardEntry(
        rank: (json['rank'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        score: (json['score'] as num?)?.toInt() ?? 0,
        me: me ?? json['me'] == true,
      );

  final int rank;
  final String name;
  final int score;
  final bool me;
}

class RunnerBoard {
  const RunnerBoard({required this.entries, this.me});

  factory RunnerBoard.fromJson(Map<String, dynamic> json) => RunnerBoard(
    entries: [
      for (final entry in (json['entries'] as List? ?? const []))
        if (entry is Map<String, dynamic>) RunnerBoardEntry.fromJson(entry),
    ],
    me: json['me'] is Map<String, dynamic>
        ? RunnerBoardEntry.fromJson(
            json['me'] as Map<String, dynamic>,
            me: true,
          )
        : null,
  );

  final List<RunnerBoardEntry> entries;

  /// The customer's own place, also when it is below the top.
  final RunnerBoardEntry? me;

  /// Whether the customer's row is already among [entries].
  bool get meShown => entries.any((e) => e.me);
}

/// The waiting game's shared leaderboard on the relay.
class RunnerBoardRepository {
  RunnerBoardRepository({required this.api, required this.isSignedIn});

  final RelayApi api;
  final bool Function() isSignedIn;

  /// The best run the relay has not heard of yet (no connection then): it
  /// goes with the next one.
  RunnerRun? _unsent;
  Duration _unsentTook = Duration.zero;

  /// Sends a finished run. Fire and forget: a failure keeps it for the
  /// next try, and the game never waits on it.
  Future<void> submit(RunnerRun run, Duration took) async {
    if (!isSignedIn() || run.score <= 0) {
      return;
    }
    final unsent = _unsent;
    final sending = unsent != null && unsent.score > run.score ? unsent : run;
    final sendingTook = identical(sending, run) ? took : _unsentTook;
    final result = await Result.guard(
      () => api.post(
        '/v1/customers/me/runner',
        body: {
          'score': sending.score,
          'coins': sending.coins,
          'seconds': sendingTook.inSeconds.clamp(1, 7200),
        },
        signedIn: true,
      ),
    );
    switch (result) {
      // No connection, or the relay was down: try this one again later.
      case Error(:final exception)
          when exception is! RelayApiException ||
              exception.status == 0 ||
              exception.status >= 500:
        _unsent = sending;
        _unsentTook = sendingTook;
      // Heard (or refused, which another try would not change).
      default:
        _unsent = null;
    }
  }

  Future<Result<RunnerBoard>> board(RunnerPeriod period) => Result.guard(
    () async => RunnerBoard.fromJson(
      await api.get(
        '/v1/customers/runner/leaderboard',
        query: {'period': period.name},
        signedIn: true,
      ),
    ),
  );
}
