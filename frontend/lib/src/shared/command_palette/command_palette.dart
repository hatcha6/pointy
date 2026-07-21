import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../core/analytics_interaction_tracker.dart';
import '../../core/storage/app_key_value_store.dart';
import '../design/design.dart';
import '../navigation/app_navigation.dart';
import '../navigation/navigation_catalog.dart';
import '../responsive/responsive.dart';

/// Module-global handle to the mounted palette, so any screen — including
/// routes pushed over the home route, which are not descendants of the scope —
/// can open it without an [InheritedWidget] lookup.
final GlobalKey<CommandPaletteScopeState> commandPaletteScopeKey =
    GlobalKey<CommandPaletteScopeState>();

/// Opens the global command palette, if one is currently mounted.
void openCommandPalette() => commandPaletteScopeKey.currentState?.open();

/// One selectable row in the command palette.
class CommandItem {
  const CommandItem({
    required this.id,
    required this.icon,
    required this.title,
    required this.onSelect,
    this.subtitle,
    this.trailing,
    this.keywords = const [],
    this.actions = const [],
    this.recent,
  });

  final String id;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Optional right-aligned value (e.g. a money amount) shown on the row.
  final String? trailing;
  final List<String> keywords;

  /// Inline secondary actions runnable straight from the row (print, reorder…).
  final List<CommandRowAction> actions;

  /// When non-null, choosing or acting on this item remembers it as a recent
  /// (entities set this; the always-listed screens and quick actions do not).
  final RecentEntry? recent;

  /// Runs when the item is chosen. Receives the scope's (home-route) context.
  final void Function(BuildContext context) onSelect;

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    if (title.toLowerCase().contains(q)) return true;
    for (final keyword in keywords) {
      if (keyword.toLowerCase().contains(q)) return true;
    }
    return false;
  }
}

/// An inline action on a [CommandItem] row (e.g. print a label, reorder).
class CommandRowAction {
  const CommandRowAction({
    required this.icon,
    required this.tooltip,
    required this.onRun,
  });

  final IconData icon;
  final String tooltip;
  final void Function(BuildContext context) onRun;
}

/// The kind of entity a recent refers to, so it can be re-opened by id.
enum RecentKind { product, customer, supplier, invoice, purchaseOrder }

/// A serialisable pointer to a recently opened entity (persisted across
/// restarts; re-opened by fetching the entity by id).
class RecentEntry {
  const RecentEntry({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final RecentKind kind;
  final int id;
  final String title;
  final String? subtitle;
  final String? trailing;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'trailing': trailing,
  };

  static RecentEntry? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! num) {
      return null;
    }
    RecentKind? kind;
    for (final candidate in RecentKind.values) {
      if (candidate.name == json['kind']) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) {
      return null;
    }
    return RecentEntry(
      kind: kind,
      id: id.toInt(),
      title: (json['title'] as String?) ?? '',
      subtitle: json['subtitle'] as String?,
      trailing: json['trailing'] as String?,
    );
  }
}

/// A labelled group of [CommandItem]s rendered under one header.
class CommandSection {
  const CommandSection(this.label, this.items);

  final String label;
  final List<CommandItem> items;
}

/// A provider of command-palette results for a query.
abstract class CommandSource {
  const CommandSource();

  String sectionLabel(AppLocalizations l10n);

  /// Async sources hit a backend on each (debounced) query; sync sources filter
  /// an in-memory list on every keystroke.
  bool get isAsync;

  /// Sync sources override this.
  List<CommandItem> filter(BuildContext context, String query) => const [];

  /// Async sources override this.
  Future<List<CommandItem>> search(BuildContext context, String query) async =>
      const [];
}

/// The always-available, instant "jump to any screen" source.
class NavigationCommandSource extends CommandSource {
  const NavigationCommandSource(this.navigation);

  final AppNavigation navigation;

  @override
  String sectionLabel(AppLocalizations l10n) =>
      l10n.commandPaletteScreensSection;

  @override
  bool get isAsync => false;

  @override
  List<CommandItem> filter(BuildContext context, String query) {
    final l10n = AppLocalizations.of(context)!;
    final items = <CommandItem>[
      for (final entry in appNavigationEntries(l10n))
        if (navigation.isDestinationAvailable(entry.destination))
          CommandItem(
            id: 'screen-${entry.destination.name}',
            icon: entry.icon,
            title: entry.label,
            keywords: entry.keywords,
            onSelect: (ctx) => navigation.navigateTo(ctx, entry.destination),
          ),
    ];
    if (query.isEmpty) {
      return items;
    }
    return items.where((item) => item.matches(query)).toList(growable: false);
  }
}

/// A debounced backend-backed source (products, customers, invoices, …).
class AsyncCommandSource<T> extends CommandSource {
  const AsyncCommandSource({
    required this.labelBuilder,
    required this.fetch,
    required this.toItem,
    this.limit = 6,
  });

  final String Function(AppLocalizations l10n) labelBuilder;
  final Future<List<T>> Function(String query) fetch;
  final CommandItem Function(T value) toItem;
  final int limit;

  @override
  String sectionLabel(AppLocalizations l10n) => labelBuilder(l10n);

  @override
  bool get isAsync => true;

  @override
  Future<List<CommandItem>> search(BuildContext context, String query) async {
    final results = await fetch(query);
    return [for (final value in results.take(limit)) toItem(value)];
  }
}

/// A fixed, in-memory set of commands (the quick actions) filtered by query.
class StaticCommandSource extends CommandSource {
  const StaticCommandSource({required this.label, required this.items});

  final String label;
  final List<CommandItem> items;

  @override
  String sectionLabel(AppLocalizations l10n) => label;

  @override
  bool get isAsync => false;

  @override
  List<CommandItem> filter(BuildContext context, String query) {
    if (query.isEmpty) {
      return items;
    }
    return items.where((item) => item.matches(query)).toList(growable: false);
  }
}

/// Store of recently opened entities — shown on the empty query so ⌘K is
/// useful before you type. Persists across restarts via [SharedPreferences].
class CommandPaletteRecents {
  CommandPaletteRecents({
    this.capacity = 8,
    this.storageKey = 'command_palette.recents.v1',
  });

  final int capacity;
  final String storageKey;
  List<RecentEntry> _entries = [];

  List<RecentEntry> get entries => List.unmodifiable(_entries);

  /// Loads persisted recents. Call once at startup; safe to call again.
  Future<void> load() async {
    try {
      final store = await AppKeyValueStore.instance();
      final raw = await store.getString(storageKey);
      if (raw == null) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      _entries = [
        for (final item in decoded)
          if (item is Map)
            if (RecentEntry.fromJson(item.cast<String, Object?>())
                case final entry?)
              entry,
      ];
    } catch (_) {
      // Ignore missing or corrupt storage.
    }
  }

  void add(RecentEntry entry) {
    _entries.removeWhere((e) => e.kind == entry.kind && e.id == entry.id);
    _entries.insert(0, entry);
    if (_entries.length > capacity) {
      _entries.removeRange(capacity, _entries.length);
    }
    unawaited(_persist());
  }

  void clear() {
    _entries = [];
    unawaited(_persist());
  }

  Future<void> _persist() async {
    try {
      final store = await AppKeyValueStore.instance();
      await store.setString(
        storageKey,
        jsonEncode([for (final entry in _entries) entry.toJson()]),
      );
    } catch (_) {
      // Best-effort; recents are a convenience, not critical state.
    }
  }
}

/// The app-wide recents store, persisted across restarts and cleared on logout.
final CommandPaletteRecents commandPaletteRecents = CommandPaletteRecents();

IconData recentKindIcon(RecentKind kind) => switch (kind) {
  RecentKind.product => Icons.inventory_2_outlined,
  RecentKind.customer => Icons.person_outline,
  RecentKind.supplier => Icons.local_shipping_outlined,
  RecentKind.invoice => Icons.request_quote_outlined,
  RecentKind.purchaseOrder => Icons.add_shopping_cart_outlined,
};

/// Surfaces [commandPaletteRecents] on the empty query, re-opening each entity
/// by id via [onOpen]. Hidden once a query is entered (live search covers it).
class RecentsCommandSource extends CommandSource {
  const RecentsCommandSource({required this.label, required this.onOpen});

  final String label;
  final void Function(BuildContext context, RecentEntry entry) onOpen;

  @override
  String sectionLabel(AppLocalizations l10n) => label;

  @override
  bool get isAsync => false;

  @override
  List<CommandItem> filter(BuildContext context, String query) {
    if (query.isNotEmpty) {
      return const [];
    }
    return [
      for (final entry in commandPaletteRecents.entries)
        CommandItem(
          id: 'recent-${entry.kind.name}-${entry.id}',
          icon: recentKindIcon(entry.kind),
          title: entry.title,
          subtitle: entry.subtitle,
          trailing: entry.trailing,
          recent: entry,
          onSelect: (ctx) => onOpen(ctx, entry),
        ),
    ];
  }
}

/// What the sheet returns when a row is chosen or one of its actions is run:
/// the callback to invoke, plus the recent to remember (if any).
class _CommandInvocation {
  const _CommandInvocation({required this.run, this.recent});

  final void Function(BuildContext context) run;
  final RecentEntry? recent;
}

/// Hosts the global command palette: a ⌘/Ctrl+K "find anything" overlay.
///
/// Mounted once inside the authenticated home (so its context lives in the
/// first route, below the app [Navigator]), it registers an app-wide hotkey and
/// exposes [open] via [commandPaletteScopeKey].
class CommandPaletteScope extends StatefulWidget {
  const CommandPaletteScope({
    super.key,
    required this.sources,
    required this.child,
  });

  final List<CommandSource> sources;
  final Widget child;

  @override
  State<CommandPaletteScope> createState() => CommandPaletteScopeState();
}

class CommandPaletteScopeState extends State<CommandPaletteScope> {
  bool _isOpen = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    unawaited(commandPaletteRecents.load());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyK) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) {
      return false;
    }
    open();
    return true;
  }

  Future<void> open() async {
    if (_isOpen || !mounted) {
      return;
    }
    _isOpen = true;
    unawaited(
      AnalyticsInteractionTracker.maybeOf(context)?.trackInteraction(
            action: 'command_palette_opened',
            target: 'command_palette',
          ) ??
          Future<void>.value(),
    );

    final invocation = await showGeneralDialog<_CommandInvocation>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: PointyColors.ink.withOpacity(0.45),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          _CommandPaletteSheet(sources: widget.sources),
      transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );

    _isOpen = false;
    if (invocation != null && mounted) {
      if (invocation.recent case final recent?) {
        commandPaletteRecents.add(recent);
      }
      // Collapse any pushed sections back to home first, so palette navigation
      // yields the same depth-2 stack the drawer produces, then act.
      Navigator.of(context).popUntil((route) => route.isFirst);
      invocation.run(context);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _CommandPaletteSheet extends StatefulWidget {
  const _CommandPaletteSheet({required this.sources});

  final List<CommandSource> sources;

  @override
  State<_CommandPaletteSheet> createState() => _CommandPaletteSheetState();
}

class _CommandPaletteSheetState extends State<_CommandPaletteSheet> {
  static const int _minAsyncQueryLength = 2;

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _selectedRowKey = GlobalKey();

  Timer? _debounce;
  String _query = '';
  int _selectedIndex = 0;

  /// Which inline action of the selected row is keyboard-focused (Tab cycles).
  /// -1 means the row's primary action (open).
  int _actionFocus = -1;
  int _searchToken = 0;
  bool _isSearching = false;
  List<CommandSection> _asyncSections = const [];

  late final List<CommandSource> _asyncSources = widget.sources
      .where((source) => source.isAsync)
      .toList(growable: false);

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim();
    setState(() {
      _query = value;
      _selectedIndex = 0;
      _actionFocus = -1;
    });
    if (trimmed.length < _minAsyncQueryLength || _asyncSources.isEmpty) {
      setState(() {
        _asyncSections = const [];
        _isSearching = false;
      });
      return;
    }
    setState(() => _isSearching = true);
    final token = ++_searchToken;
    _debounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_runSearch(trimmed, token));
    });
  }

  Future<void> _runSearch(String query, int token) async {
    final results = await Future.wait(
      _asyncSources.map(
        (source) => source
            .search(context, query)
            .catchError((_) => const <CommandItem>[]),
      ),
    );
    if (!mounted || token != _searchToken) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final sections = <CommandSection>[];
    for (var i = 0; i < _asyncSources.length; i++) {
      if (results[i].isNotEmpty) {
        sections.add(
          CommandSection(_asyncSources[i].sectionLabel(l10n), results[i]),
        );
      }
    }
    setState(() {
      _asyncSections = sections;
      _isSearching = false;
    });
  }

  List<CommandSection> _sections() {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim();
    final sections = <CommandSection>[];
    for (final source in widget.sources) {
      if (source.isAsync) {
        continue;
      }
      final items = source.filter(context, query);
      if (items.isNotEmpty) {
        sections.add(CommandSection(source.sectionLabel(l10n), items));
      }
    }
    sections.addAll(_asyncSections);
    return sections;
  }

  void _move(int delta) {
    final count = _sections().fold<int>(0, (sum, s) => sum + s.items.length);
    if (count == 0) {
      return;
    }
    setState(() {
      _selectedIndex = (_selectedIndex + delta) % count;
      _actionFocus = -1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _selectedRowKey.currentContext;
      if (rowContext != null) {
        Scrollable.ensureVisible(
          rowContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  CommandItem? _selectedItem() {
    final items = [for (final section in _sections()) ...section.items];
    if (items.isEmpty) {
      return null;
    }
    return items[_selectedIndex.clamp(0, items.length - 1)];
  }

  /// Tab/Shift+Tab cycle the selected row's inline actions: -1 (open) → 0 → 1
  /// → … → -1, so the workflow stays keyboard-only.
  void _cycleAction(int direction) {
    final item = _selectedItem();
    if (item == null || item.actions.isEmpty) {
      return;
    }
    final count = item.actions.length;
    var next = _actionFocus + direction;
    if (next >= count) {
      next = -1;
    } else if (next < -1) {
      next = count - 1;
    }
    setState(() => _actionFocus = next);
  }

  void _handleEscape() {
    if (_actionFocus >= 0) {
      setState(() => _actionFocus = -1);
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _submit() {
    final item = _selectedItem();
    if (item == null) {
      return;
    }
    if (_actionFocus >= 0 && _actionFocus < item.actions.length) {
      final action = item.actions[_actionFocus];
      Navigator.of(
        context,
      ).pop(_CommandInvocation(run: action.onRun, recent: item.recent));
      return;
    }
    Navigator.of(
      context,
    ).pop(_CommandInvocation(run: item.onSelect, recent: item.recent));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final isCompact = MediaQuery.sizeOf(context).width < 600;

    final sections = _sections();
    final itemCount = sections.fold<int>(0, (sum, s) => sum + s.items.length);
    final selectedIndex = itemCount == 0
        ? -1
        : _selectedIndex.clamp(0, itemCount - 1);

    final rows = <Widget>[];
    CommandItem? selectedItem;
    var itemIndex = 0;
    for (final section in sections) {
      rows.add(_SectionHeader(label: section.label));
      for (final item in section.items) {
        final selected = itemIndex == selectedIndex;
        if (selected) {
          selectedItem = item;
        }
        rows.add(
          _CommandRow(
            key: selected ? _selectedRowKey : null,
            item: item,
            selected: selected,
            actionFocusIndex: selected ? _actionFocus : -1,
            onTap: () => Navigator.of(
              context,
            ).pop(_CommandInvocation(run: item.onSelect, recent: item.recent)),
            onRunAction: (action) => Navigator.of(
              context,
            ).pop(_CommandInvocation(run: action.onRun, recent: item.recent)),
            onHover: _hover(itemIndex),
          ),
        );
        itemIndex++;
      }
    }

    final surface = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PointyRadii.dialog),
        boxShadow: PointyShadows.overlay,
      ),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.dialog),
        clipBehavior: Clip.antiAlias,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
            const SingleActivator(LogicalKeyboardKey.tab): () =>
                _cycleAction(1),
            const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
                _cycleAction(-1),
            const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(spacing.md),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.go,
                  onChanged: _onQueryChanged,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: l10n.commandPaletteSearchHint,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).deleteButtonTooltip,
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _controller.clear();
                              _onQueryChanged('');
                            },
                          ),
                  ),
                ),
              ),
              SizedBox(
                height: 2,
                child: _isSearching
                    ? const LinearProgressIndicator(minHeight: 2)
                    : null,
              ),
              Divider(height: 1, color: colors.line),
              Flexible(
                child: (itemCount == 0 && !_isSearching)
                    ? _EmptyResults(label: l10n.commandPaletteNoResults)
                    : ListView(
                        controller: _scrollController,
                        padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
                        children: rows,
                      ),
              ),
              if (!isCompact) ...[
                Divider(height: 1, color: colors.line),
                Container(
                  width: double.infinity,
                  color: colors.surfaceSunken,
                  padding: EdgeInsets.symmetric(
                    horizontal: spacing.md,
                    vertical: spacing.sm,
                  ),
                  child: Text(
                    (selectedItem?.actions.isNotEmpty ?? false)
                        ? '${l10n.commandPaletteFooterHint} · '
                              '${l10n.commandPaletteActionsHint}'
                        : l10n.commandPaletteFooterHint,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          top: isCompact ? spacing.md : 72,
          left: spacing.md,
          right: spacing.md,
          bottom: spacing.md,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: isCompact ? double.infinity : 520,
            ),
            child: surface,
          ),
        ),
      ),
    );
  }

  VoidCallback _hover(int index) => () {
    if (_selectedIndex != index) {
      setState(() => _selectedIndex = index);
    }
  };
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.md,
        spacing.xs,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: colors.mutedInk,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({
    super.key,
    required this.item,
    required this.selected,
    required this.actionFocusIndex,
    required this.onTap,
    required this.onRunAction,
    required this.onHover,
  });

  final CommandItem item;
  final bool selected;

  /// Index of the keyboard-focused inline action (-1 = none / primary open).
  final int actionFocusIndex;
  final VoidCallback onTap;
  final void Function(CommandRowAction action) onRunAction;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final foreground = selected ? colors.primaryDark : colors.ink;

    return Material(
      color: selected ? PointyColors.primaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onHover: (hovering) {
          if (hovering) {
            onHover();
          }
        },
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                item.icon,
                size: 20,
                color: selected ? colors.primaryStrong : colors.mutedInk,
              ),
              SizedBox(width: spacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.subtitle case final subtitle?)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                  ],
                ),
              ),
              for (var i = 0; i < item.actions.length; i++) ...[
                SizedBox(width: spacing.xs),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  style: i == actionFocusIndex
                      ? IconButton.styleFrom(
                          backgroundColor: PointyColors.primaryContainer,
                        )
                      : null,
                  tooltip: item.actions[i].tooltip,
                  color: i == actionFocusIndex
                      ? colors.primaryDark
                      : (selected ? colors.primaryStrong : colors.mutedInk),
                  onPressed: () => onRunAction(item.actions[i]),
                  icon: Icon(item.actions[i].icon),
                ),
              ],
              if (item.trailing case final trailing?) ...[
                SizedBox(width: spacing.sm),
                Text(
                  trailing,
                  style: switch (textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  )) {
                    final style? => PointyTypography.numeric(style),
                    null => null,
                  },
                ),
              ],
              if (selected) ...[
                SizedBox(width: spacing.xs),
                Icon(
                  Icons.subdirectory_arrow_left,
                  size: 16,
                  color: colors.primaryStrong,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsets.all(spacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_outlined, color: colors.mutedInk, size: 32),
          SizedBox(height: spacing.sm),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}
