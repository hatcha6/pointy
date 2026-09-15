import 'package:flutter/foundation.dart';

import '../../../core/authorization.dart';
import '../../../core/storage/app_key_value_store.dart';
import '../content/learning_library.dart';
import '../models/learning_guide.dart';
import '../models/learning_query.dart';
import '../search/learning_search.dart';

/// Drives the learning catalogue: the query, the filtered result, and which
/// guides this user has marked finished.
///
/// The library itself is compiled-in content, so there is no repository and no
/// loading state — filtering 70 guides is a synchronous list operation, and
/// pretending otherwise would add a spinner to a screen that can always paint
/// immediately.
class LearningViewModel extends ChangeNotifier {
  LearningViewModel({required this.capabilities, required this.userId});

  final AuthorizationCapabilities capabilities;

  /// Whose progress this is.
  ///
  /// A till is shared: the cashier who marked "returns" finished this morning
  /// is not the one reading the catalogue this evening, and one device-wide
  /// list would show each of them the other's ticks.
  final int userId;

  String get _finishedStorageKey => 'learning.finished_guides.$userId';

  LearningQuery _query = const LearningQuery();
  LearningQuery get query => _query;

  Set<String> _finished = <String>{};

  /// Ids this user has marked as finished. Local to this device — an owner
  /// asking "has Fatima been trained on returns?" is a different feature with a
  /// server-side record behind it, and pretending this answers it would be
  /// worse than not answering.
  Set<String> get finished => Set.unmodifiable(_finished);

  List<LearningGuide> _results = const [];
  List<LearningGuide> get results => _results;

  bool _restored = false;

  Future<void> restoreProgress() async {
    if (_restored) {
      return;
    }
    _restored = true;
    try {
      final store = await AppKeyValueStore.instance();
      final stored = await store.getStringList(_finishedStorageKey);
      if (stored == null || stored.isEmpty) {
        return;
      }
      // Drop ids that no longer exist so a renamed guide cannot keep a stale
      // "finished" mark alive forever.
      _finished = stored.where(learningGuidesById.containsKey).toSet();
      _applyQuery();
    } catch (_) {
      // Progress is a convenience; a storage failure must never block the
      // catalogue from opening.
    }
  }

  void setSearch(String value) {
    if (value == _query.search) {
      return;
    }
    _query = _query.copyWith(search: value);
    _applyQuery();
  }

  void setQuery(LearningQuery value) {
    _query = value;
    _applyQuery();
  }

  void selectTrack(LearningTrack? track) {
    _query = track == null
        ? _query.copyWith(clearTrack: true)
        : _query.copyWith(track: track);
    _applyQuery();
  }

  void clearFilters() {
    _query = _query.cleared();
    _applyQuery();
  }

  bool isFinished(String guideId) => _finished.contains(guideId);

  Future<void> toggleFinished(String guideId) async {
    if (!_finished.remove(guideId)) {
      _finished.add(guideId);
    }
    _applyQuery();
    try {
      final store = await AppKeyValueStore.instance();
      await store.setStringList(_finishedStorageKey, _finished.toList());
    } catch (_) {
      // Same as above: the in-memory mark still works for this session.
    }
  }

  /// How many guides the catalogue would show with no search and no filters —
  /// the denominator for "you have finished 4 of 70".
  int get libraryCount => learningLibrary.length;

  int get finishedCount => _finished.length;

  /// Re-runs the whole pipeline. Cheap enough to do on every keystroke: the
  /// search indexes are prebuilt, so this is a scan over ~70 records.
  void _applyQuery() {
    final tokens = tokenizeSearchText(normalizeSearchText(_query.search));
    final scored = <(LearningGuide, int)>[];

    for (final guide in learningLibrary) {
      if (!_passesFilters(guide)) {
        continue;
      }
      if (tokens.isEmpty) {
        scored.add((guide, 0));
        continue;
      }
      final score = learningSearchIndexes[guide.id]?.score(tokens) ?? 0;
      if (score > 0) {
        scored.add((guide, score));
      }
    }

    scored.sort((a, b) => _compare(a, b, hasSearch: tokens.isNotEmpty));
    _results = [for (final entry in scored) entry.$1];
    notifyListeners();
  }

  bool _passesFilters(LearningGuide guide) {
    if (_query.track != null && guide.track != _query.track) {
      return false;
    }
    final levelOk = switch (_query.level) {
      LearningLevelFilter.all => true,
      LearningLevelFilter.beginner => guide.level == LearningLevel.beginner,
      LearningLevelFilter.intermediate =>
        guide.level == LearningLevel.intermediate,
      LearningLevelFilter.advanced => guide.level == LearningLevel.advanced,
    };
    if (!levelOk) {
      return false;
    }
    final kindOk = switch (_query.kind) {
      LearningKindFilter.all => true,
      LearningKindFilter.walkthrough => guide.kind == LearningKind.walkthrough,
      LearningKindFilter.concept => guide.kind == LearningKind.concept,
      LearningKindFilter.reference => guide.kind == LearningKind.reference,
    };
    if (!kindOk) {
      return false;
    }
    if (_query.audience == LearningAudienceFilter.myPermissions) {
      final capability = guide.capability;
      if (capability != null && !capabilities.allows(capability)) {
        return false;
      }
    }
    return switch (_query.progress) {
      LearningProgressFilter.all => true,
      LearningProgressFilter.unfinished => !_finished.contains(guide.id),
      LearningProgressFilter.finished => _finished.contains(guide.id),
    };
  }

  int _compare(
    (LearningGuide, int) a,
    (LearningGuide, int) b, {
    required bool hasSearch,
  }) {
    // While searching, relevance wins over every chosen order: someone who
    // typed a word wants the best match first, not the curriculum's opinion.
    if (hasSearch) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) {
        return byScore;
      }
    }
    return switch (_query.sort) {
      LearningSort.recommended => _byLibraryOrder(a.$1, b.$1),
      LearningSort.level => _byLevel(a.$1, b.$1),
      LearningSort.shortest => _byMinutes(a.$1, b.$1),
      LearningSort.alphabetical => _byTitle(a.$1, b.$1),
    };
  }

  int _byLibraryOrder(LearningGuide a, LearningGuide b) {
    return (learningGuideOrder[a.id] ?? 0).compareTo(
      learningGuideOrder[b.id] ?? 0,
    );
  }

  int _byLevel(LearningGuide a, LearningGuide b) {
    final byLevel = a.level.index.compareTo(b.level.index);
    return byLevel != 0 ? byLevel : _byLibraryOrder(a, b);
  }

  int _byMinutes(LearningGuide a, LearningGuide b) {
    final byMinutes = a.minutes.compareTo(b.minutes);
    return byMinutes != 0 ? byMinutes : _byLibraryOrder(a, b);
  }

  int _byTitle(LearningGuide a, LearningGuide b) {
    // Compare the normalized forms so alef variants and tashkeel do not throw
    // otherwise-adjacent titles apart.
    return normalizeSearchText(a.title).compareTo(normalizeSearchText(b.title));
  }

  /// Guides linked from [guide], skipping ids that no longer resolve.
  List<LearningGuide> relatedTo(LearningGuide guide) {
    return [for (final id in guide.related) ?learningGuidesById[id]];
  }

  /// Seeds the first result set. Call once after construction.
  void initialize() => _applyQuery();
}
