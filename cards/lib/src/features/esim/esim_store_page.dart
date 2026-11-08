import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/arabic_search.dart';
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
import '../../shared/pressable.dart';
import '../../shared/relay_error_text.dart';
import '../../shared/section_header.dart';
import '../../shared/side_back.dart';
import '../../shared/skeleton.dart';
import '../../shared/esim_card_art.dart';
import 'esim_destination_page.dart';
import 'esim_format.dart';
import 'esim_page.dart';
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

/// The popular destinations that are on the shelf, most wanted first.
List<EsimDestinationRow> esimPopularDestinations(EsimShelf shelf) => [
  for (final code in _popularCountries)
    ...shelf.destinations.where((d) => d.country == code),
];

/// The eSIM shelf: search or pick a destination. Whether this phone takes
/// eSIMs is said at the top, and the customer's own eSIMs come first.
class EsimStorePage extends StatefulWidget {
  const EsimStorePage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: screenSettings('esim_store'),
      builder: (_) => const EsimStorePage(),
    ),
  );

  @override
  State<EsimStorePage> createState() => _EsimStorePageState();
}

class _EsimStorePageState extends State<EsimStorePage> {
  final _search = TextEditingController();
  EsimKind _kind = EsimKind.local;
  String _query = '';
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
    final shelf = await dependencies.esim.loadShelf();
    final mine = dependencies.auth.isSignedIn
        ? await dependencies.esim.esims()
        : null;
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

  List<EsimDestinationRow> _matches(EsimShelf shelf) {
    if (_query.isEmpty) {
      return shelf.destinations.where((d) => d.kind == _kind).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    }
    // A search looks everywhere, whichever tab is on.
    return shelf.destinations
        .where((d) => matchesSearch(_query, [d.name, d.key, d.country]))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shelf = _shelf;
    return SideBack(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !SideBack.active(context),
          scrolledUnderElevation: 0,
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
    final page = CardsLayout.page(
      context,
      top: 0,
      bottom: MediaQuery.paddingOf(context).bottom + CardsSpace.xl,
    );
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
    final popular = !searching && _kind == EsimKind.local
        ? esimPopularDestinations(shelf)
        : const <EsimDestinationRow>[];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(top: 0, bottom: page.bottom),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          pad(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.esimStoreTitle, style: theme.textTheme.headlineLarge),
                const SizedBox(height: CardsSpace.xs),
                Text(
                  l10n.esimStoreSubtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: CardsSpace.md),
                const EsimSupportBanner(),
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) => setState(() => _query = value.trim()),
                  decoration: InputDecoration(
                    hintText: l10n.esimSearchHint,
                    prefixIcon: const Icon(Icons.search_rounded),
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
                ),
              ],
            ),
          ),
          if (searching) ...[
            const SizedBox(height: CardsSpace.lg),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(CardsSpace.xl),
                child: Text(
                  l10n.esimNoMatch,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              pad(_DestinationGroup(rows: rows)),
          ] else ...[
            if (_mine.isNotEmpty) ...[
              header(l10n.esimMineTitle),
              _MineShelf(esims: _mine, gutter: page.left, onChanged: _load),
            ],
            const SizedBox(height: CardsSpace.xl),
            pad(
              SegmentedPill<EsimKind>(
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
            if (_kind == EsimKind.local) ...[
              if (popular.isNotEmpty) ...[
                header(l10n.esimPopular),
                _PopularShelf(rows: popular, gutter: page.left),
              ],
              header(l10n.esimAllCountries),
              pad(_DestinationGroup(rows: rows)),
            ] else ...[
              const SizedBox(height: CardsSpace.lg),
              pad(_TileGrid(rows: rows)),
            ],
            header(l10n.esimHowTitle),
            pad(const _HowItWorks()),
          ],
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => ListView(
    padding: CardsLayout.page(context, top: CardsSpace.sm),
    children: [
      const Skeleton(height: 40, radius: CardsRadii.tile),
      const SizedBox(height: CardsSpace.lg),
      const Skeleton(height: 52, radius: CardsRadii.field),
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
  const _DestinationTile({required this.row, required this.width});

  final EsimDestinationRow row;
  final double width;

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
                    child: EsimCardArt(name: '', country: row.country),
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
              Text(
                row.kind == EsimKind.local
                    ? l10n.esimEntryFrom(formatMoney(l10n, row.fromPrice))
                    : '${l10n.esimCountriesCount(row.countries)} · ${l10n.esimEntryFrom(formatMoney(l10n, row.fromPrice))}',
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
          _DestinationTile(row: rows[i], width: 172),
        ],
      ],
    ),
  );
}

/// Regions and the world: few enough to show as cards.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.rows});

  final List<EsimDestinationRow> rows;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = (constraints.maxWidth - CardsSpace.md) / 2;
      return Wrap(
        spacing: CardsSpace.md,
        runSpacing: CardsSpace.lg,
        children: [
          for (final row in rows) _DestinationTile(row: row, width: width),
        ],
      );
    },
  );
}

class _DestinationGroup extends StatelessWidget {
  const _DestinationGroup({required this.rows});

  final List<EsimDestinationRow> rows;

  @override
  Widget build(BuildContext context) =>
      Grouped(children: [for (final row in rows) _DestinationRow(row: row)]);
}

class _DestinationRow extends StatelessWidget {
  const _DestinationRow({required this.row});

  final EsimDestinationRow row;

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
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  l10n.esimEntryFrom(formatMoney(l10n, row.fromPrice)),
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
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

/// Three steps, for someone who has never had an eSIM.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget step(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.all(CardsSpace.lg),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 20,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return Grouped(
      children: [
        step(Icons.public_rounded, l10n.esimHow1Title, l10n.esimHow1Body),
        step(Icons.download_rounded, l10n.esimHow2Title, l10n.esimHow2Body),
        step(Icons.flight_land_rounded, l10n.esimHow3Title, l10n.esimHow3Body),
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
