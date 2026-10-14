import '../../../data/models/moamalat.dart';

/// One payment line of the open sheet, as the swipe planner sees it.
class SwipeTender {
  const SwipeTender({
    required this.index,
    required this.isCard,
    required this.amount,
  });

  final int index;
  final bool isCard;
  final double amount;
}

/// What to do with a swipe nothing on the sheet accounts for.
enum SwipeAction {
  /// The terminal took LESS than the card line: shrink the line to what was
  /// taken and add a line for the rest.
  splitShortfall,

  /// The terminal took MORE than the card line: only the terminal can give
  /// the difference back. Warn; change nothing.
  overcharged,

  /// No card line yet (the tender is cash, say) and a swipe is waiting —
  /// likely taken before the sheet opened. Offer to use it.
  useAsCard,
}

class SwipeSuggestion {
  const SwipeSuggestion({
    required this.swipe,
    required this.action,
    this.tenderIndex,
  });

  final MoamalatSwipe swipe;
  final SwipeAction action;

  /// The line it applies to: the waiting card line, or (for [useAsCard]) the
  /// active line the swipe would replace.
  final int? tenderIndex;
}

class SwipePlan {
  const SwipePlan({
    this.seen = const {},
    this.suggestions = const [],
    this.automatic,
  });

  /// Card line index → the swipe that proves it (same amount).
  final Map<int, MoamalatSwipe> seen;

  /// Swipes nothing accounts for, each with what it would mean.
  final List<SwipeSuggestion> suggestions;

  /// The one correction safe to make without asking: a single unaccounted
  /// swipe, smaller than the single card line still waiting for one.
  final SwipeSuggestion? automatic;

  bool get isEmpty => seen.isEmpty && suggestions.isEmpty;
}

bool _same(double a, double b) => (a - b).abs() < 0.005;

/// Pair the terminal's unclaimed swipes with the sheet's lines.
///
/// Exact amounts pair first, oldest swipe to the first card line. What is
/// left is a mistake to point out, never silently absorbed — except the one
/// unambiguous case: one stray swipe for less than the one waiting card line,
/// which is the cashier keying the wrong figure into the terminal.
/// [ignored] are swipes the cashier said are not this sale's, or already
/// acted on.
SwipePlan planSwipes({
  required List<SwipeTender> tenders,
  required List<MoamalatSwipe> swipes,
  Set<String> ignored = const {},
  int? activeIndex,
}) {
  // Oldest first: the earlier swipe belongs to the earlier line.
  final pool = [
    for (final swipe in swipes.reversed)
      if (!ignored.contains(swipe.rrn)) swipe,
  ];
  final seen = <int, MoamalatSwipe>{};
  final waiting = <SwipeTender>[];
  for (final tender in tenders) {
    if (!tender.isCard || tender.amount <= 0) continue;
    final match = pool.indexWhere((s) => _same(s.amount, tender.amount));
    if (match >= 0) {
      seen[tender.index] = pool.removeAt(match);
    } else {
      waiting.add(tender);
    }
  }
  if (pool.isEmpty) {
    return SwipePlan(seen: seen);
  }
  final suggestions = <SwipeSuggestion>[];
  if (waiting.isNotEmpty) {
    final target = waiting.first;
    for (final swipe in pool) {
      suggestions.add(
        SwipeSuggestion(
          swipe: swipe,
          tenderIndex: target.index,
          action: swipe.amount < target.amount
              ? SwipeAction.splitShortfall
              : SwipeAction.overcharged,
        ),
      );
    }
  } else if (seen.isEmpty) {
    // No card line at all: the swipe may be this sale's, rung up before the
    // sheet opened. Offer it against the active line.
    final target = tenders.where((t) => t.amount > 0).toList();
    final index =
        (activeIndex != null && target.any((t) => t.index == activeIndex))
        ? activeIndex
        : (target.isEmpty ? null : target.first.index);
    if (index != null) {
      final line = tenders.firstWhere((t) => t.index == index);
      for (final swipe in pool) {
        suggestions.add(
          SwipeSuggestion(
            swipe: swipe,
            tenderIndex: index,
            action: swipe.amount <= line.amount + 0.004
                ? SwipeAction.useAsCard
                : SwipeAction.overcharged,
          ),
        );
      }
    }
  }
  final automatic =
      waiting.length == 1 &&
          suggestions.length == 1 &&
          suggestions.single.action == SwipeAction.splitShortfall
      ? suggestions.single
      : null;
  return SwipePlan(
    seen: seen,
    suggestions: automatic == null ? suggestions : const [],
    automatic: automatic,
  );
}
