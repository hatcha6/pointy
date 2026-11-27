import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'runner_sprites.dart';

/// One finished run.
class RunnerRun {
  const RunnerRun({required this.score, required this.coins, required this.at});

  factory RunnerRun.fromJson(Map<String, dynamic> json) => RunnerRun(
    score: (json['score'] as num?)?.toInt() ?? 0,
    coins: (json['coins'] as num?)?.toInt() ?? 0,
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime(2026),
  );

  final int score;
  final int coins;
  final DateTime at;

  Map<String, Object> toJson() => {
    'score': score,
    'coins': coins,
    'at': at.toIso8601String(),
  };
}

/// The waiting game's records on this phone: the best runs, the runner
/// chosen, and whether it plays sound. Kept across orders and app launches,
/// so the next wait has a score to beat.
class RunnerRecords extends ChangeNotifier {
  RunnerRecords({this.preferences});

  /// Where they are kept; none in tests and previews.
  final SharedPreferencesAsync? preferences;

  /// How many runs the table keeps.
  static const int kept = 10;

  static const _key = 'runner.records';

  List<RunnerRun> _top = const [];
  int _played = 0;
  int _coins = 0;
  bool _muted = false;
  RunnerCharacter _character = RunnerCharacter.green;
  Future<void>? _loading;

  /// The best runs, best first.
  List<RunnerRun> get top => _top;
  int get best => _top.isEmpty ? 0 : _top.first.score;
  int get played => _played;
  int get coins => _coins;
  bool get muted => _muted;
  RunnerCharacter get character => _character;

  bool unlocked(RunnerCharacter character) => best >= character.unlock;

  /// Reads them once; later calls wait for the same read.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final raw = await _read();
    if (raw == null) {
      return;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _top = [
        for (final run in (json['top'] as List? ?? const []))
          if (run is Map<String, dynamic>) RunnerRun.fromJson(run),
      ]..sort((a, b) => b.score.compareTo(a.score));
      _played = (json['played'] as num?)?.toInt() ?? 0;
      _coins = (json['coins'] as num?)?.toInt() ?? 0;
      _muted = json['muted'] == true;
      _character = RunnerCharacter.byName(json['character'] as String?);
      if (!unlocked(_character)) {
        _character = RunnerCharacter.green;
      }
    } on Object {
      // Unreadable records start over; the game still plays.
    }
    notifyListeners();
  }

  Future<String?> _read() async {
    try {
      return await preferences?.getString(_key);
    } on Object {
      return null;
    }
  }

  /// Adds a finished run. Returns its place in the table (0 is the best),
  /// or null when it did not make it.
  int? add(RunnerRun run) {
    _played++;
    _coins += run.coins;
    int? place;
    if (run.score > 0) {
      final top = [..._top, run]..sort((a, b) => b.score.compareTo(a.score));
      final index = top.indexOf(run);
      if (index < kept) {
        place = index;
        _top = top.take(kept).toList();
      }
    }
    _save();
    return place;
  }

  /// The runners a best of [after] unlocks that a best of [before] did not.
  List<RunnerCharacter> unlockedBy(int before, int after) => [
    for (final character in RunnerCharacter.values)
      if (character.unlock > before && character.unlock <= after) character,
  ];

  set muted(bool value) {
    _muted = value;
    _save();
  }

  set character(RunnerCharacter value) {
    if (!unlocked(value)) {
      return;
    }
    _character = value;
    _save();
  }

  void _save() {
    // After the current frame's work: a run counted as its page closes
    // must not ping widgets that are being taken down with it.
    scheduleMicrotask(notifyListeners);
    final json = jsonEncode({
      'top': [for (final run in _top) run.toJson()],
      'played': _played,
      'coins': _coins,
      'muted': _muted,
      'character': _character.name,
    });
    preferences?.setString(_key, json).catchError((Object _) {
      // Not kept this time; the run still counted on screen.
    });
  }
}
