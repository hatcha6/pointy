/// The searches a till ran against a provider that found something — what the
/// top-up screen opens on instead of an empty box.
///
/// Most of an agency's trade is the same customers coming back every month,
/// so the list is how a regular becomes one tap rather than a number read out
/// again. A row is only ever a way back to a search: running it asks the
/// provider again, live, and nothing on it is sold from.
library;

import 'integration_provider.dart';
import 'query.dart';

int _toInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _toDate(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

class IntegrationRecentSearch {
  const IntegrationRecentSearch({
    required this.id,
    required this.term,
    this.searchBy = '',
    this.matchCount = 1,
    this.cardNo = '',
    this.holderName = '',
    this.packageName = '',
    this.subscriberLabel = '',
    this.searchCount = 1,
    this.lastSearchedAt,
  });

  final int id;

  /// What was typed. Running the search again sends exactly this.
  final String term;

  /// The provider's code for what [term] is — LNET's `mobile`, `username`
  /// or `contract_number`. Empty for a provider that searches one way only.
  final String searchBy;

  /// How many lines it matched last time. More than one is a household the
  /// cashier had to choose between, and running it again brings the choice
  /// back rather than guessing.
  final int matchCount;

  /// The line it found, when it found exactly one: HD Box's card number,
  /// LNET's username. Not always what was typed — a phone search finds a
  /// username.
  final String cardNo;

  /// The name the provider has on the line, where it shares one.
  final String holderName;
  final String packageName;

  /// Who the shop says the card belongs to — the linked customer, or a name
  /// typed at the till. Empty until somebody says.
  final String subscriberLabel;

  /// How many times it has been searched. Repeats fold into one row.
  final int searchCount;
  final DateTime? lastSearchedAt;

  bool get foundSeveralLines => matchCount > 1;

  /// The mode it ran under, when it is one this app knows.
  IntegrationSearchMode? get searchMode =>
      integrationSearchModeFromJson(searchBy);

  factory IntegrationRecentSearch.fromJson(Map<String, Object?> json) {
    return IntegrationRecentSearch(
      id: _toInt(json['id']),
      term: json['term']?.toString() ?? '',
      searchBy: json['search_by']?.toString() ?? '',
      matchCount: _toInt(json['match_count'], fallback: 1),
      cardNo: json['card_no']?.toString() ?? '',
      holderName: json['holder_name']?.toString() ?? '',
      packageName: json['package_name']?.toString() ?? '',
      subscriberLabel: json['subscriber_label']?.toString() ?? '',
      searchCount: _toInt(json['search_count'], fallback: 1),
      lastSearchedAt: _toDate(json['last_searched_at']),
    );
  }
}

/// One cursor page of recent searches, newest first.
///
/// Cursor rather than page number because the list is written to while it is
/// read: every search at every till lands at its head, and a page number
/// would hand a scrolling cashier the same row twice.
class IntegrationRecentSearchPage {
  const IntegrationRecentSearchPage({
    required this.searches,
    required this.hasMore,
    this.nextCursor,
  });

  final List<IntegrationRecentSearch> searches;
  final bool hasMore;
  final String? nextCursor;

  factory IntegrationRecentSearchPage.fromJson(Map<String, Object?> json) {
    final nextCursor = nextPageCursor(json['next']);
    return IntegrationRecentSearchPage(
      searches: (json['results'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(IntegrationRecentSearch.fromJson)
          .toList(growable: false),
      hasMore: nextCursor != null,
      nextCursor: nextCursor,
    );
  }
}
