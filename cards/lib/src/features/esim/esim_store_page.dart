import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/arabic_search.dart';
import '../../core/money.dart';
import '../../core/result.dart';
import '../../data/models/esim.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_theme.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/empty_state.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../../shared/relay_error_text.dart';
import '../../shared/section_header.dart';
import '../../shared/side_back.dart';
import '../../shared/skeleton.dart';
import '../../shared/esim_card_art.dart';
import 'esim_banner_art.dart';
import 'esim_destination_page.dart';
import 'esim_entry.dart';
import 'esim_format.dart';
import 'esim_page.dart';
import 'esim_share.dart';
import '../links/cards_link.dart';
import 'esim_support_banner.dart';

/// Where Libyan travellers go most: shown first, by country code.
const _popularCountries = [
  'TR',
  'EG',
  'TN',
  'SA',
  'AE',
  'IT',
  'DE',
  'GB',
  'MT',
  'JO',
];

/// How the shelf's list is ordered.
enum EsimSort { name, cheapest }

/// What the eSIM shelf opens on, as a link can ask: a search, a tab, a trip.
class EsimShelfFilter {
  const EsimShelfFilter({
    this.query = '',
    this.kind = EsimKind.local,
    this.minDays = 0,
    this.minMb = 0,
    this.offersOnly = false,
    this.sort = EsimSort.name,
  });

  final String query;
  final EsimKind kind;
  final int minDays;
  final int minMb;
  final bool offersOnly;
  final EsimSort sort;
}

/// A destination on the list, and what it costs for the trip asked for.
typedef EsimHit = ({EsimDestinationRow row, Money from});

extension on EsimHit {
  /// The regular price to strike through: only while the price shown is the
  /// promotion's own cheapest.
  Money? get struck =>
      row.promo != null && from == row.fromPrice ? row.regularFromPrice : null;
}

List<EsimHit> esimHits(List<EsimDestinationRow> rows) => [
  for (final row in rows) (row: row, from: row.fromPrice),
];

const _dayChoices = [7, 15, 30];
const _dataChoices = [1024, 3072, 5120, 10240, 20480];

/// A data size as a chip says it, written the one way in every language.
String _dataLabel(int mb) => '\u2066${mb ~/ 1024} GB+\u2069';

/// The shelf's filters: offers, the trip's length, the data needed, the order.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.gutter,
    required this.wrap,
    required this.hasOffers,
    required this.offersOnly,
    required this.minDays,
    required this.minMb,
    required this.sort,
    required this.filtering,
    required this.onOffers,
    required this.onDays,
    required this.onData,
    required this.onSort,
    required this.onClear,
  });

  final double gutter;

  /// On a wide page the chips wrap; on a phone they swipe.
  final bool wrap;
  final bool hasOffers;
  final bool offersOnly;
  final int minDays;
  final int minMb;
  final EsimSort sort;
  final bool filtering;
  final VoidCallback onOffers;
  final ValueChanged<int> onDays;
  final ValueChanged<int> onData;
  final ValueChanged<EsimSort> onSort;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chips = <Widget>[
      // First, so it is in sight however far the chips swipe.
      if (filtering)
        Pressable(
          onTap: onClear,
          child: _ChipFace(
            label: l10n.esimFilterClear,
            icon: Icons.close_rounded,
            selected: false,
            plain: true,
          ),
        ),
      if (hasOffers || offersOnly)
        Pressable(
          onTap: () {
            Haptics.select();
            onOffers();
          },
          child: _ChipFace(
            label: l10n.esimFilterOffers,
            icon: Icons.local_offer_rounded,
            selected: offersOnly,
          ),
        ),
      _MenuChip<int>(
        label: minDays > 0
            ? l10n.esimFilterDaysOption(minDays)
            : l10n.esimFilterDays,
        icon: Icons.event_rounded,
        selected: minDays > 0,
        value: minDays,
        choices: [
          (0, l10n.esimFilterAny),
          for (final days in _dayChoices)
            (days, l10n.esimFilterDaysOption(days)),
        ],
        onChanged: onDays,
      ),
      _MenuChip<int>(
        label: minMb > 0 ? _dataLabel(minMb) : l10n.esimFilterData,
        icon: Icons.signal_cellular_alt_rounded,
        selected: minMb > 0,
        value: minMb,
        choices: [
          (0, l10n.esimFilterAny),
          for (final mb in _dataChoices) (mb, _dataLabel(mb)),
        ],
        onChanged: onData,
      ),
      _MenuChip<EsimSort>(
        label: sort == EsimSort.cheapest
            ? l10n.esimSortCheapest
            : l10n.esimSortTitle,
        icon: Icons.swap_vert_rounded,
        selected: sort != EsimSort.name,
        value: sort,
        choices: [
          (EsimSort.name, l10n.esimSortName),
          (EsimSort.cheapest, l10n.esimSortCheapest),
        ],
        onChanged: onSort,
      ),
    ];
    if (wrap) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        child: Wrap(
          spacing: CardsSpace.sm,
          runSpacing: CardsSpace.sm,
          children: chips,
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: gutter),
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: CardsSpace.sm),
            chips[i],
          ],
        ],
      ),
    );
  }
}

/// A chip that opens a short list to choose from.
class _MenuChip<T> extends StatelessWidget {
  const _MenuChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final T value;
  final List<(T, String)> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<T>(
      tooltip: '',
      initialValue: value,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CardsRadii.tile),
      ),
      onSelected: (choice) {
        Haptics.select();
        onChanged(choice);
      },
      itemBuilder: (context) => [
        for (final (choice, text) in choices)
          PopupMenuItem<T>(
            value: choice,
            child: Row(
              children: [
                Expanded(child: Text(text)),
                if (choice == value)
                  Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
              ],
            ),
          ),
      ],
      child: _ChipFace(
        label: label,
        icon: icon,
        selected: selected,
        menu: true,
      ),
    );
  }
}

class _ChipFace extends StatelessWidget {
  const _ChipFace({
    required this.label,
    required this.icon,
    required this.selected,
    this.menu = false,
    this.plain = false,
  });

  final String label;
  final IconData icon;
  final bool selected;

  /// Opens a list: a small arrow says so.
  final bool menu;

  /// No surface of its own: «مسح».
  final bool plain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected
        ? scheme.onPrimary
        : plain
        ? CardsTheme.link(theme)
        : scheme.onSurface;
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: CardsSpace.md + 2),
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary
            : plain
            ? Colors.transparent
            : scheme.surface,
        borderRadius: BorderRadius.circular(CardsRadii.pill),
        border: plain || selected
            ? null
            : Border.all(color: scheme.outline.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: CardsSpace.xs + 2),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (menu) ...[
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 18, color: foreground),
          ],
        ],
      ),
    );
  }
}

/// The flags the eSIM picture shows: where people go most, then whatever else
/// is on the shelf.
List<String> esimBannerCountries(EsimShelf shelf) => {
  for (final row in esimPopularDestinations(shelf)) row.country,
  for (final row in shelf.destinations)
    if (row.kind == EsimKind.local && row.country.isNotEmpty) row.country,
}.take(5).toList();

/// The popular destinations that are on the shelf, most wanted first.
List<EsimDestinationRow> esimPopularDestinations(EsimShelf shelf) => [
  for (final code in _popularCountries)
    ...shelf.destinations.where((d) => d.country == code),
];

/// The eSIM shelf: search or pick a destination. Whether this phone takes
/// eSIMs is said at the top, and the customer's own eSIMs come first.
class EsimStorePage extends StatefulWidget {
  const EsimStorePage({super.key, this.filter = const EsimShelfFilter()});

  /// What the shelf opens on: a link's search, tab and filters.
  final EsimShelfFilter filter;

  static Future<void> open(
    BuildContext context, {
    EsimShelfFilter filter = const EsimShelfFilter(),
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: screenSettings('esim_store'),
      builder: (_) => EsimStorePage(filter: filter),
    ),
  );

  @override
  State<EsimStorePage> createState() => _EsimStorePageState();
}

class _EsimStorePageState extends State<EsimStorePage> {
  late final _search = TextEditingController(text: widget.filter.query);
  late EsimKind _kind = widget.filter.kind;
  late String _query = widget.filter.query.trim();
  late int _minDays = widget.filter.minDays;
  late int _minMb = widget.filter.minMb;
  late bool _offersOnly = widget.filter.offersOnly;
  late EsimSort _sort = widget.filter.sort;
  EsimShelf? _shelf;
  Object? _error;
  List<CustomerEsim> _mine = const [];
  bool _started = false;
  ValueNotifier<int>? _changes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      final dependencies = CardsScope.of(context);
      dependencies.esimCompatibility.load();
      // A purchase made from here shows in «شرائحي» on the way back.
      _changes = dependencies.esim.changes..addListener(_load);
      _load();
    }
  }

  @override
  void dispose() {
    _changes?.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final dependencies = CardsScope.of(context);
    // Side by side: neither waits on the other.
    final (shelf, mine) = await (
      dependencies.esim.loadShelf(),
      dependencies.auth.isSignedIn
          ? dependencies.esim.esims()
          : Future<Result<List<CustomerEsim>>?>.value(),
    ).wait;
    if (!mounted) {
      return;
    }
    setState(() {
      switch (shelf) {
        case Ok(:final value):
          _shelf = value;
          _error = null;
        case Error(:final exception):
          _error = exception;
      }
      if (mine case Ok(:final value)) {
        _mine = value.where((e) => !e.ended).toList();
      }
    });
  }

  /// The shelf as it shows now, for a link: its search, tab and filters.
  EsimShelfLink _link() => EsimShelfLink(
    query: _query,
    kind: _kind == EsimKind.local ? '' : _kind.name,
    days: _minDays,
    gb: _minMb ~/ 1024,
    offers: _offersOnly,
    cheapest: _sort == EsimSort.cheapest,
  );

  /// A filter that changes which rows show, or what they cost.
  bool get _filtering =>
      _offersOnly || _minDays > 0 || _minMb > 0 || _sort != EsimSort.name;

  void _clearFilters() => setState(() {
    _offersOnly = false;
    _minDays = 0;
    _minMb = 0;
    _sort = EsimSort.name;
  });

  /// What a search reads of each destination, folded.
  static final _searchable = Expando<String>();

  /// The destinations to show, each with what it costs for the trip asked
  /// for: the cheapest of its plans long and large enough.
  List<EsimHit> _matches(EsimShelf shelf) {
    final searching = _query.isNotEmpty;
    final words = searchWords(_query);
    final hits = <EsimHit>[];
    for (final row in shelf.destinations) {
      // A search looks everywhere, whichever tab is on, and finds a region
      // by a country in it.
      if (searching
          ? !matchesWords(
              words,
              // Folded once for each place: a region names every country
              // it covers, and this runs at every letter typed.
              _searchable[row] ??= searchText([
                row.name,
                row.key,
                row.country,
                ...row.covers,
              ]),
            )
          : row.kind != _kind) {
        continue;
      }
      if (_offersOnly && row.promo == null) {
        continue;
      }
      var from = row.fromPrice;
      if ((_minDays > 0 || _minMb > 0) && row.planList.isNotEmpty) {
        Money? best;
        for (final plan in row.planList) {
          final fits =
              plan.days >= _minDays && (plan.unlimited || plan.mb >= _minMb);
          if (fits && (best == null || plan.price.compareTo(best) < 0)) {
            best = plan.price;
          }
        }
        if (best == null) {
          continue;
        }
        from = best;
      }
      hits.add((row: row, from: from));
    }
    if (_sort == EsimSort.cheapest) {
      hits.sort((a, b) => a.from.compareTo(b.from));
    } else if (!searching) {
      hits.sort((a, b) => a.row.name.compareTo(b.row.name));
    }
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shelf = _shelf;
    final side = SideBack.active(context);
    final sells = shelf != null && shelf.available;
    return SideBack(
      actions: [
        if (sells)
          EsimShareButton.side(
            context,
            link: _link,
            title: () => l10n.esimStoreTitle,
          ),
      ],
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !side,
          scrolledUnderElevation: 0,
          actions: [
            if (sells && !side)
              EsimShareButton(link: _link, title: () => l10n.esimStoreTitle),
          ],
        ),
        body: Builder(
          builder: (context) {
            if (shelf == null) {
              return _error != null
                  ? EmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: l10n.esimLoadFailed,
                      body: relayErrorText(l10n, _error!),
                      actionLabel: l10n.esimTryAgain,
                      onAction: _load,
                    )
                  : const _Loading();
            }
            if (!shelf.available) {
              return EmptyState(
                icon: Icons.sim_card_outlined,
                title: l10n.esimClosedTitle,
                body: l10n.esimClosedBody,
              );
            }
            return _content(context, shelf);
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context, EsimShelf shelf) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final media = (
      size: MediaQuery.sizeOf(context),
      padding: MediaQuery.paddingOf(context),
    );
    // A tablet or a desktop: the shelf takes the room, in columns.
    final wide = esimStoreWide(context);
    final page = CardsLayout.page(
      context,
      top: 0,
      bottom: media.padding.bottom + CardsSpace.xl,
      maxWidth: wide ? CardsLayout.shelf : CardsLayout.readable,
    );
    final inner = media.size.width - page.left - page.right;
    final columns = !wide
        ? 1
        : inner >= 960
        ? 3
        : 2;
    Widget pad(Widget child) => Padding(
      padding: EdgeInsets.only(left: page.left, right: page.right),
      child: child,
    );
    Widget header(String title) => pad(
      SectionHeader(
        title: title,
        padding: const EdgeInsets.only(
          top: CardsSpace.xl,
          bottom: CardsSpace.md,
        ),
      ),
    );
    final searching = _query.isNotEmpty;
    final rows = _matches(shelf);
    // The shelves of picks show while nothing narrows the list.
    final browsing = !searching && !_filtering && _kind == EsimKind.local;
    final popular = browsing
        ? esimPopularDestinations(shelf)
        : const <EsimDestinationRow>[];
    final offers = browsing
        ? shelf.destinations.where((d) => d.promo != null).toList()
        : const <EsimDestinationRow>[];
    final filters = _FilterBar(
      gutter: page.left,
      wrap: wide,
      hasOffers: shelf.destinations.any((d) => d.promo != null),
      offersOnly: _offersOnly,
      minDays: _minDays,
      minMb: _minMb,
      sort: _sort,
      filtering: _filtering,
      onOffers: () => setState(() => _offersOnly = !_offersOnly),
      onDays: (days) => setState(() => _minDays = days),
      onData: (mb) => setState(() => _minMb = mb),
      onSort: (sort) => setState(() => _sort = sort),
      onClear: _clearFilters,
    );
    final none = Padding(
      padding: const EdgeInsets.all(CardsSpace.xl),
      child: Text(
        searching && !_filtering ? l10n.esimNoMatch : l10n.esimFilterNone,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final search = TextField(
      controller: _search,
      textInputAction: TextInputAction.search,
      onChanged: (value) => setState(() => _query = value.trim()),
      decoration: InputDecoration(
        hintText: l10n.esimSearchHint,
        prefixIcon: const Icon(Icons.search_rounded),
        border: _heroField,
        enabledBorder: _heroField,
        focusedBorder: _heroField,
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: l10n.esimSearchClear,
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
      ),
    );
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(top: CardsSpace.xs, bottom: page.bottom),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          pad(
            _StoreHero(
              wide: wide,
              countries: esimBannerCountries(shelf),
              search: search,
            ),
          ),
          const SizedBox(height: CardsSpace.lg),
          pad(const EsimSupportBanner()),
          if (searching) ...[
            filters,
            const SizedBox(height: CardsSpace.md),
            if (rows.isEmpty)
              none
            else
              pad(_DestinationGroup(rows: rows, columns: columns)),
          ] else ...[
            if (_mine.isNotEmpty) ...[
              pad(
                SectionHeader(
                  title: l10n.esimMineTitle,
                  padding: const EdgeInsets.only(bottom: CardsSpace.md),
                ),
              ),
              if (wide)
                pad(
                  _Columns(
                    columns: columns,
                    children: [
                      for (final esim in _mine)
                        EsimCard(
                          esim: esim,
                          onTap: () async {
                            await EsimPage.open(context, esim.iccid);
                            _load();
                          },
                        ),
                    ],
                  ),
                )
              else
                _MineShelf(esims: _mine, gutter: page.left, onChanged: _load),
              const SizedBox(height: CardsSpace.xl),
            ],
            pad(
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: SegmentedPill<EsimKind>(
                    segments: [
                      (EsimKind.local, l10n.esimKindLocal),
                      (EsimKind.regional, l10n.esimKindRegional),
                      (EsimKind.global, l10n.esimKindGlobal),
                    ],
                    selected: _kind,
                    onChanged: (kind) {
                      Haptics.select();
                      setState(() => _kind = kind);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: CardsSpace.md),
            filters,
            if (browsing) ...[
              if (offers.isNotEmpty) ...[
                header(l10n.esimOffersTitle),
                if (wide)
                  pad(_TileGrid(rows: esimHits(offers), tile: 190))
                else
                  _PopularShelf(rows: offers, gutter: page.left),
              ],
              if (popular.isNotEmpty) ...[
                header(l10n.esimPopular),
                if (wide)
                  pad(_TileGrid(rows: esimHits(popular), tile: 190))
                else
                  _PopularShelf(rows: popular, gutter: page.left),
              ],
              header(l10n.esimAllCountries),
              pad(_DestinationGroup(rows: rows, columns: columns)),
            ] else if (rows.isEmpty)
              none
            else if (_kind == EsimKind.local) ...[
              header(l10n.esimResultsCount(rows.length)),
              pad(_DestinationGroup(rows: rows, columns: columns)),
            ] else ...[
              const SizedBox(height: CardsSpace.lg),
              pad(_TileGrid(rows: rows, tile: wide ? 230 : 0)),
            ],
            header(l10n.esimHowTitle),
            pad(EsimHowItWorks(row: wide)),
          ],
        ],
      ),
    );
  }
}

/// Whether the eSIM shelf lays out in columns: a tablet, a desktop.
bool esimStoreWide(BuildContext context) {
  return MediaQuery.sizeOf(context).width -
          MediaQuery.paddingOf(context).horizontal >=
      720;
}

final _heroField = OutlineInputBorder(
  borderRadius: BorderRadius.circular(CardsRadii.field),
  borderSide: BorderSide.none,
);

/// The shelf's opening: the question, the search that answers it, and the
/// picture of where an eSIM goes.
class _StoreHero extends StatelessWidget {
  const _StoreHero({
    required this.wide,
    required this.countries,
    required this.search,
  });

  final bool wide;
  final List<String> countries;
  final Widget search;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final art = wide ? math.min(box.maxWidth * 0.42, 460.0) : 150.0;
        final inset = wide ? CardsSpace.xxl : CardsSpace.lg + CardsSpace.xs;
        final words = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.esimEntryKicker,
              style: theme.textTheme.labelLarge?.copyWith(
                color: const Color(0xFFF7C777),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: CardsSpace.xs),
            Text(
              l10n.esimStoreTitle,
              style:
                  (wide
                          ? theme.textTheme.displaySmall
                          : theme.textTheme.headlineMedium)
                      ?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
            ),
            const SizedBox(height: CardsSpace.xs),
            Text(
              l10n.esimStoreSubtitle,
              style:
                  (wide
                          ? theme.textTheme.bodyLarge
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(color: Colors.white.withValues(alpha: 0.84)),
            ),
          ],
        );
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CardsRadii.card),
            boxShadow: CardsShadows.hero,
            gradient: const LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: esimDeepColors,
              stops: [0, 0.55, 1],
            ),
          ),
          child: Stack(
            children: [
              PositionedDirectional(
                end: 0,
                top: 0,
                bottom: wide ? 0 : null,
                height: wide ? null : 140,
                width: art,
                child: ExcludeSemantics(
                  child: EsimBannerArt(countries: countries),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(inset),
                child: wide
                    ? Padding(
                        padding: EdgeInsetsDirectional.only(end: art),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            words,
                            const SizedBox(height: CardsSpace.md),
                            const EsimPerks(),
                            const SizedBox(height: CardsSpace.xl),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 520),
                              child: search,
                            ),
                          ],
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 96),
                            child: Padding(
                              padding: EdgeInsetsDirectional.only(
                                end: art - inset,
                              ),
                              child: words,
                            ),
                          ),
                          const SizedBox(height: CardsSpace.lg),
                          search,
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// [children] in rows of [columns], each row's cards as tall as its tallest.
class _Columns extends StatelessWidget {
  const _Columns({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < children.length; i += columns)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : CardsSpace.md),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = i; j < i + columns; j++) ...[
                  if (j > i) const SizedBox(width: CardsSpace.md),
                  Expanded(
                    child: j < children.length
                        ? children[j]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ),
    ],
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => ListView(
    padding: CardsLayout.page(
      context,
      top: CardsSpace.xs,
      maxWidth: esimStoreWide(context)
          ? CardsLayout.shelf
          : CardsLayout.readable,
    ),
    children: [
      const Skeleton(height: 220, radius: CardsRadii.card),
      const SizedBox(height: CardsSpace.xl),
      for (var i = 0; i < 2; i++)
        const Padding(
          padding: EdgeInsets.only(bottom: CardsSpace.lg),
          child: Skeleton(height: 150, radius: CardsRadii.card),
        ),
    ],
  );
}

void _openDestination(BuildContext context, EsimDestinationRow row) {
  Haptics.tap();
  EsimDestinationPage.open(context, row.key, name: row.name);
}

/// A destination as a card on a rack, the way the home shelf shows a brand: its
/// flag's card, then its name and lowest price.
class _DestinationTile extends StatelessWidget {
  const _DestinationTile({required this.hit, required this.width});

  final EsimHit hit;
  final double width;

  EsimDestinationRow get row => hit.row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: row.name,
        child: Pressable(
          onTap: () => _openDestination(context, row),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(CardsRadii.tile),
                  boxShadow: CardsShadows.art,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(CardsRadii.tile),
                  child: AspectRatio(
                    aspectRatio: kCardAspect,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        EsimCardArt(name: '', country: row.country),
                        if (row.promo case final promo?)
                          PositionedDirectional(
                            start: CardsSpace.sm,
                            bottom: CardsSpace.sm,
                            child: Pill(
                              text: esimPromoLabel(l10n, promo),
                              tone: PillTone.promo,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: CardsSpace.sm),
              Text(
                row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              Text.rich(
                TextSpan(
                  children: [
                    if (row.kind != EsimKind.local)
                      TextSpan(
                        text: '${l10n.esimCountriesCount(row.countries)} · ',
                      ),
                    TextSpan(
                      text: l10n.esimEntryFrom(formatMoney(l10n, hit.from)),
                      style: hit.struck == null
                          ? null
                          : TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                    ),
                    if (hit.struck case final regular?) ...[
                      const TextSpan(text: '  '),
                      TextSpan(
                        text: formatMoney(l10n, regular),
                        style: const TextStyle(
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    ],
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where people go most, to swipe through.
class _PopularShelf extends StatelessWidget {
  const _PopularShelf({required this.rows, required this.gutter});

  final List<EsimDestinationRow> rows;
  final double gutter;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    padding: EdgeInsets.symmetric(horizontal: gutter),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(width: CardsSpace.md),
          _DestinationTile(hit: esimHits(rows)[i], width: 172),
        ],
      ],
    ),
  );
}

/// Destinations as cards, in as many columns as fit: two on a phone, more
/// where tiles about [tile] wide have the room.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.rows, this.tile = 0});

  final List<EsimHit> rows;
  final double tile;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = tile <= 0
          ? 2
          : (constraints.maxWidth / tile).floor().clamp(2, 6);
      // A hair under, so rounding never drops the last tile to a new row.
      final width =
          (constraints.maxWidth - CardsSpace.md * (columns - 1)) / columns -
          0.01;
      return Wrap(
        spacing: CardsSpace.md,
        runSpacing: CardsSpace.lg,
        children: [
          for (final hit in rows) _DestinationTile(hit: hit, width: width),
        ],
      );
    },
  );
}

/// Destinations as rows: one list on a phone, side by side lists, read down
/// each, where there is room.
class _DestinationGroup extends StatelessWidget {
  const _DestinationGroup({required this.rows, this.columns = 1});

  final List<EsimHit> rows;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final count = math.min(columns, rows.length);
    if (count <= 1) {
      return Grouped(
        children: [for (final hit in rows) _DestinationRow(hit: hit)],
      );
    }
    final each = (rows.length / count).ceil();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < count; c++) ...[
          if (c > 0) const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Grouped(
              children: [
                for (final hit in rows.skip(c * each).take(each))
                  _DestinationRow(hit: hit),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _DestinationRow extends StatelessWidget {
  const _DestinationRow({required this.hit});

  final EsimHit hit;

  EsimDestinationRow get row => hit.row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: () => _openDestination(context, row),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          CardsSpace.lg,
          CardsSpace.md,
          CardsSpace.md,
          CardsSpace.md,
        ),
        child: Row(
          children: [
            EsimFlag(country: row.country, width: 36),
            const SizedBox(width: CardsSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.name, style: theme.textTheme.titleSmall),
                  if (row.kind != EsimKind.local)
                    Text(
                      l10n.esimCountriesCount(row.countries),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
            if (row.promo case final promo?) ...[
              Pill(text: esimPromoLabel(l10n, promo), tone: PillTone.promo),
              const SizedBox(width: CardsSpace.sm),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      l10n.esimEntryFrom(formatMoney(l10n, hit.from)),
                      style: hit.struck == null
                          ? theme.textTheme.bodyMedium?.copyWith(color: muted)
                          : theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                    ),
                    if (hit.struck case final regular?)
                      Text(
                        formatMoney(l10n, regular),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: CardsSpace.xs),
            Icon(Icons.chevron_right_rounded, size: 20, color: muted),
          ],
        ),
      ),
    );
  }
}

/// The customer's eSIMs, to swipe through; one fills the width.
class _MineShelf extends StatelessWidget {
  const _MineShelf({
    required this.esims,
    required this.gutter,
    required this.onChanged,
  });

  final List<CustomerEsim> esims;
  final double gutter;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final full = MediaQuery.sizeOf(context).width - gutter * 2;
    final width = esims.length == 1 ? full : full * 0.84;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: EdgeInsets.symmetric(horizontal: gutter),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < esims.length; i++) ...[
              if (i > 0) const SizedBox(width: CardsSpace.md),
              SizedBox(
                width: width,
                child: EsimCard(
                  esim: esims[i],
                  onTap: () async {
                    await EsimPage.open(context, esims[i].iccid);
                    onChanged();
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Three steps, for someone who has never had an eSIM: a list on a phone,
/// three cards in a [row] where there is room.
class EsimHowItWorks extends StatelessWidget {
  const EsimHowItWorks({super.key, this.row = false});

  final bool row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final steps = [
      (Icons.public_rounded, l10n.esimHow1Title, l10n.esimHow1Body),
      (Icons.download_rounded, l10n.esimHow2Title, l10n.esimHow2Body),
      (Icons.flight_land_rounded, l10n.esimHow3Title, l10n.esimHow3Body),
    ];
    Widget badge(IconData icon) => Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 20, color: theme.colorScheme.onPrimaryContainer),
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (row) {
      return _Columns(
        columns: 3,
        children: [
          for (final (icon, title, body) in steps)
            Grouped(
              children: [
                Padding(
                  padding: const EdgeInsets.all(CardsSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      badge(icon),
                      const SizedBox(height: CardsSpace.md),
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(body, style: muted),
                    ],
                  ),
                ),
              ],
            ),
        ],
      );
    }
    return Grouped(
      children: [
        for (final (icon, title, body) in steps)
          Padding(
            padding: const EdgeInsets.all(CardsSpace.lg),
            child: Row(
              children: [
                badge(icon),
                const SizedBox(width: CardsSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      Text(body, style: muted),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The customer's eSIMs as cards: what is left on each, one tap from its page.
class EsimMineList extends StatelessWidget {
  const EsimMineList({super.key, required this.esims, this.onChanged});

  final List<CustomerEsim> esims;

  /// Told when the customer comes back from an eSIM's page.
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final esim in esims)
        Padding(
          padding: const EdgeInsets.only(bottom: CardsSpace.md),
          child: EsimCard(
            esim: esim,
            onTap: () async {
              await EsimPage.open(context, esim.iccid);
              onChanged?.call();
            },
          ),
        ),
    ],
  );
}

/// One eSIM: where, for whom, how much is left, and a nudge when it runs low.
class EsimCard extends StatelessWidget {
  const EsimCard({super.key, required this.esim, required this.onTap});

  final CustomerEsim esim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usage = esim.usage;
    final low = usage.runningOut(DateTime.now());
    final left = usage.left;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(CardsSpace.lg),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(CardsRadii.card),
          boxShadow: CardsShadows.raised,
          border: Border.all(
            color: scheme.outline.withValues(alpha: 0.6),
            width: 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                EsimFlag(country: esim.country, width: 40),
                const SizedBox(width: CardsSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        esim.destinationName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      if (esim.label.isNotEmpty)
                        Text(
                          esim.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      EsimPlanLine(
                        data: esim.data,
                        days: esim.days,
                        unlimited: esim.unlimited,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  esimStatusText(l10n, usage.status),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: usage.over ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (left != null && usage.status == EsimStatus.active) ...[
              const SizedBox(height: CardsSpace.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(CardsRadii.pill),
                child: LinearProgressIndicator(
                  value: left,
                  minHeight: 6,
                  color: usage.dataLow ? scheme.error : scheme.primary,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ],
            if (usage.status == EsimStatus.notActive) ...[
              const SizedBox(height: CardsSpace.md),
              Text(
                esim.gift ? l10n.esimTapToSend : l10n.esimTapToInstall,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: CardsTheme.link(theme),
                ),
              ),
            ],
            if (low) ...[
              const SizedBox(height: CardsSpace.sm),
              Text(
                esim.rechargeable
                    ? l10n.esimRunningOutTopUp
                    : l10n.esimRunningOutNew,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
