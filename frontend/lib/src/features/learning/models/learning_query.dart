import 'learning_guide.dart';

/// Which track the catalogue is narrowed to. `all` is the resting state.
enum LearningTrackFilter { all, track }

/// Difficulty filter.
enum LearningLevelFilter { all, beginner, intermediate, advanced }

/// Guide-kind filter — steps to follow, an explanation, or something to look up.
enum LearningKindFilter { all, walkthrough, concept, reference }

/// Whether to show the whole library or only the guides whose subject this user
/// can actually reach with their permissions.
enum LearningAudienceFilter { all, myPermissions }

/// Progress filter, driven by the locally stored "finished" marks.
enum LearningProgressFilter { all, unfinished, finished }

/// Sort order for the catalogue.
enum LearningSort {
  /// The library's own order: tracks in the sequence a shop learns them,
  /// guides in the sequence a person should read them. The default, because a
  /// curated path is the whole point of a learning module.
  recommended,

  /// Easiest first — the order a brand-new hire wants.
  level,

  /// Quickest first, for reading between customers.
  shortest,

  /// By title, for finding something you already know the name of.
  alphabetical,
}

/// The catalogue's full query: the search term plus every filter and the sort.
class LearningQuery {
  const LearningQuery({
    this.search = '',
    this.track,
    this.level = LearningLevelFilter.all,
    this.kind = LearningKindFilter.all,
    this.audience = LearningAudienceFilter.all,
    this.progress = LearningProgressFilter.all,
    this.sort = LearningSort.recommended,
  });

  final String search;

  /// Null means every track.
  final LearningTrack? track;

  final LearningLevelFilter level;
  final LearningKindFilter kind;
  final LearningAudienceFilter audience;
  final LearningProgressFilter progress;
  final LearningSort sort;

  /// How many filters the user has set, for the funnel badge.
  ///
  /// Sort is deliberately excluded here and counted separately by the control
  /// bar: reordering a list can never empty it, so blaming an empty catalogue
  /// on the sort would send the reader to clear the wrong thing.
  int get activeFilterCount {
    var count = 0;
    if (track != null) count++;
    if (level != LearningLevelFilter.all) count++;
    if (kind != LearningKindFilter.all) count++;
    if (audience != LearningAudienceFilter.all) count++;
    if (progress != LearningProgressFilter.all) count++;
    return count;
  }

  bool get hasFilters => activeFilterCount > 0;

  LearningQuery copyWith({
    String? search,
    LearningTrack? track,
    bool clearTrack = false,
    LearningLevelFilter? level,
    LearningKindFilter? kind,
    LearningAudienceFilter? audience,
    LearningProgressFilter? progress,
    LearningSort? sort,
  }) {
    return LearningQuery(
      search: search ?? this.search,
      track: clearTrack ? null : (track ?? this.track),
      level: level ?? this.level,
      kind: kind ?? this.kind,
      audience: audience ?? this.audience,
      progress: progress ?? this.progress,
      sort: sort ?? this.sort,
    );
  }

  /// Drops the search term and every filter, keeping the sort — the shape the
  /// "clear" escape in the empty state needs.
  LearningQuery cleared() => LearningQuery(sort: sort);
}
